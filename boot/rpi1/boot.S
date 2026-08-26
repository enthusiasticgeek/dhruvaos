/* Dhruva Phase 0 boot code -- BCM2835 / Pi 1 Model B (ARM1176JZF-S, ARMv6).
 * QEMU's raspi1ap machine model loads this ELF directly via -kernel and
 * jumps to _start with SVC mode, interrupts masked, MMU/caches off --
 * the same state real BCM2835 firmware leaves the ARM core in after it
 * releases reset. No vector table needed yet (Phase 2 adds one for IRQs).
 *
 * ARMv6 has no `wfe`/`wfi` in the form later cores use, so the halt loop
 * below is a plain branch, not a low-power wait -- correctness first,
 * power-awareness is Phase 5's job, not boot code's.
 */

.section ".text.boot"
.global _start

_start:
    ldr sp, =_stack_top

    /* QEMU's ELF loader does not clear .bss -- do it ourselves before
     * any vani code (which may rely on zero-initialized statics) runs. */
    ldr r0, =__bss_start
    ldr r1, =__bss_end
    mov r2, #0
clear_bss:
    cmp r0, r1
    bge clear_bss_done
    str r2, [r0]
    add r0, r0, #4
    b clear_bss
clear_bss_done:

    bl kernel_main

hang:
    b hang
