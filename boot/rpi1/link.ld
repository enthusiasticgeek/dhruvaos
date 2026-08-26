/* Dhruva Phase 0 linker script -- BCM2835 / Pi 1 Model B.
 * 0x8000 is the conventional Raspberry Pi kernel load address (matches
 * real hardware's GPU-firmware loader too, not just QEMU's -kernel path)
 * -- kept the same on purpose so this script doesn't need to change when
 * this eventually runs on the real board.
 */

ENTRY(_start)

SECTIONS
{
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

    /* No exception unwinding on bare metal -- discard rather than link
     * the personality-routine references these would otherwise pull in. */
    /DISCARD/ : { *(.ARM.exidx*) *(.ARM.extab*) }
}
