/* Dhruva Phase 0/2 boot code -- BCM2835 / Pi 1 Model B (ARM1176JZF-S, ARMv6).
 * QEMU's raspi1ap machine model loads this ELF directly via -kernel and
 * jumps to _start with SVC mode, interrupts masked, MMU/caches off --
 * the same state real BCM2835 firmware leaves the ARM core in after it
 * releases reset.
 *
 * ARMv6 has no `wfe`/`wfi` in the form later cores use, so the halt loop
 * below is a plain branch, not a low-power wait -- correctness first,
 * power-awareness is Phase 5's job, not boot code's.
 *
 * Phase 2 addition: give IRQ mode its own banked stack pointer before
 * anything else runs. ARM IRQ mode has separate banked r13(sp)/r14(lr)
 * from every other mode, so entering IRQ mode with sp_irq still zero
 * (its reset-time value) would corrupt memory at address 0 -- exactly
 * where the vector table lives -- the instant the first interrupt
 * arrives. Interrupts stay globally masked (the CPSR I-bit, untouched
 * here) until kernel_main explicitly unmasks them after the timer/
 * interrupt-controller setup in vani completes; this only prepares the
 * stack IRQ mode will use once that happens. */
.section ".text.boot"
.global _start

_start:
    ldr sp, =_stack_top

    mrs r0, cpsr
    bic r1, r0, #0x1F
    orr r1, r1, #0x12      /* IRQ mode */
    msr cpsr_c, r1
    ldr sp, =_irq_stack_top
    bic r1, r0, #0x1F
    orr r1, r1, #0x17      /* Round 38: Abort mode -- same reasoning as
                             * IRQ above: entering Abort mode with sp_abt
                             * still at its reset-time value (likely 0,
                             * corrupting the vector table the instant a
                             * Data/Prefetch Abort fires) was harmless
                             * only because nothing before this round
                             * ever gave the CPU a reason to actually
                             * take one. This round's MMU work makes
                             * permission faults a real, expected event. */
    msr cpsr_c, r1
    ldr sp, =_abort_stack_top
    bic r1, r0, #0x1F
    orr r1, r1, #0x13      /* back to SVC mode */
    msr cpsr_c, r1
    ldr sp, =_stack_top    /* restore SVC's own sp (clobbered above) */

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

    /* Round 38: page table lives in .bss (mmu_init.S), so it must be
     * built AFTER clear_bss above, not before -- otherwise the zero
     * fill would wipe out every descriptor mmu_init just wrote. */
    bl mmu_init

    bl kernel_main

hang:
    b hang
