/* Stage-0 A/B kernel-slot loader linker script -- BCM2835 / Pi 1 Model B.
 * 0x8000 is the fixed physical address GPU firmware loads the file
 * named `kernel.img` at -- this program now permanently IS that file
 * (see boot/rpi1/link.ld's own header comment for why the real DhruvaOS
 * kernel moved to 0x00200000 instead).
 *
 * Deliberately far simpler than the real kernel's own link.ld: no MMU
 * (stage-0 never turns it on, flat physical addressing throughout), so
 * no 1MB W^X alignment, no per-exception-mode stacks beyond SVC (IRQ/
 * FIQ are masked for this program's entire lifetime, never unmasked),
 * no domain-stack regions.
 */

ENTRY(_start)

SECTIONS
{
    . = 0x8000;

    .vectors : { KEEP(*(.vectors)) }
    .text.boot : { *(.text.boot) }
    .text : { *(.text*) }
    .rodata : { *(.rodata*) }

    . = ALIGN(4);
    .data : { *(.data*) }

    . = ALIGN(4);
    __bss_start = .;
    .bss : { *(.bss*) *(COMMON) }
    __bss_end = .;

    /* 8KB stack -- generous for a program with no recursion, no heap,
     * and a largest single local (block_buf, 512 bytes) known exactly
     * at compile time. */
    . = ALIGN(16);
    . = . + 0x2000;
    _stage0_stack_top = .;

    /* Same libgcc/__aeabi_uidiv unwind-table requirement boot/rpi1/
     * link.ld's own comment explains -- stage0_main.c's unsigned
     * division pulls in libgcc.a's unwind-arm.o, which references
     * __exidx_start/__exidx_end unconditionally. */
    .ARM.exidx : { __exidx_start = .; *(.ARM.exidx*) __exidx_end = .; }
    .ARM.extab : { *(.ARM.extab*) }
}
