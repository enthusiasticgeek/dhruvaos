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

    . = ALIGN(16);
    .data : { *(.data*) }

    . = ALIGN(16);
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    __bss_end = .;

    /* 16KB boot stack for EL1, growing down from _stack_top -- same
     * size class as boot/rpi1/link.ld's own main task stack. No
     * separate IRQ/Abort-mode stacks yet (AArch64 has no banked-per-
     * mode SP the way ARM32 does -- SP_EL1 is the only stack pointer
     * this v1 kernel needs, since it runs entirely at EL1 with
     * interrupts masked; a future round enabling real interrupts
     * will need to decide whether EL1 exceptions share this stack or
     * get their own, once there's an actual handler that does
     * meaningful work instead of just reporting and halting). */
    . = ALIGN(16);
    . = . + 0x4000;
    _stack_top = .;
}
