/* Dhruva Phase 0/2 linker script -- BCM2835 / Pi 1 Model B.
 * 0x8000 is the conventional Raspberry Pi kernel load address (matches
 * real hardware's GPU-firmware loader too, not just QEMU's -kernel path)
 * -- kept the same on purpose so this script doesn't need to change when
 * this eventually runs on the real board.
 */

ENTRY(_start)

SECTIONS
{
    /* ARMv6 has no VBAR -- the vector table must live at address 0
     * (low vectors, the reset default) or not work at all. This is a
     * genuinely separate region from the main image below; the linker
     * happily places two disjoint regions in one output file, and
     * KEEP() stops --gc-sections from discarding a section nothing
     * ever calls via a normal branch (the vector table is only ever
     * reached by hardware exception dispatch). */
    . = 0x0;
    .vectors : { KEEP(*(.vectors)) }

    . = 0x8000;

    .text.boot : { *(.text.boot) }
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }

    . = ALIGN(4);
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    __bss_end = .;

    /* 16KB boot stack, growing down from _stack_top. */
    . = ALIGN(16);
    . = . + 0x4000;
    _stack_top = .;

    /* 4KB IRQ-mode stack, growing down from _irq_stack_top -- small on
     * purpose: irq_entry.S does minimal work on this stack before
     * calling into vani, which needs headroom of its own but nothing
     * like the 16KB a full task stack gets. (Briefly bumped to 32KB
     * while chasing what turned out to be BUG-229, a vani-compiler bug
     * unrelated to stack size at all -- reverted once the real cause
     * was found and fixed upstream.) */
    . = ALIGN(16);
    . = . + 0x1000;
    _irq_stack_top = .;

    /* No exception unwinding on bare metal -- discard rather than link
     * the personality-routine references these would otherwise pull in. */
    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) }
}
