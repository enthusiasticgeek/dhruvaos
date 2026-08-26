/* Dhruva Phase 2 -- IRQ entry/exit (ARM32), now with real preemption.
 *
 * Step A (BUG-229 fixed, tick delivery proven) always returned to
 * whatever was interrupted. This step lets the timer tick actually
 * switch which task runs -- the core of "preemptive," not just
 * "periodic."
 *
 * Why the FULL register set (r0-r12), not just the callee-saved r4-r11
 * Phase 1's cooperative yield_now uses: yield_now is a real `bl` call,
 * so AAPCS already guarantees the caller-saved registers (r0-r3, r12)
 * are dead by the time control reaches it -- nothing to preserve. This
 * routine can't rely on that anymore: if scheduler_switch_from_irq
 * below decides to switch to a genuinely different task, the CURRENT
 * task's r0-r3/r12 must survive on ITS OWN stack until it's resumed
 * later, since nothing else will remember them. Saving everything,
 * always, is what makes "resume this task later, from any point it
 * was ever interrupted at" possible.
 *
 * ARM IRQ mode has its own banked r13(sp)/r14(lr), set up once in
 * boot.S -- entering IRQ mode doesn't disturb whatever stack the
 * interrupted task was using, which is exactly why the full-context
 * save below can safely push onto *that* stack (via `stmdb sp!`, still
 * using IRQ mode's own banked sp) and read the interrupted task's real
 * per-task stack only indirectly, through the pointer scheduler_
 * switch_from_irq hands back.
 */

.section ".text"
.global irq_entry
irq_entry:
    sub lr, lr, #4               /* IRQ's lr is 4 ahead of the instruction
                                   * that should actually resume */
    stmdb sp!, {r0-r12, lr}       /* 14 words = 56 bytes */
    mrs r0, spsr
    stmdb sp!, {r0, r1}           /* spsr + one padding word = 8 bytes,
                                   * keeping the total 64 bytes (8-byte
                                   * AAPCS alignment; see BUG-229 writeup
                                   * for what happens when this is off
                                   * by a word). */

    bl irq_dispatch               /* ack + reschedule the timer, print --
                                   * unrelated to *which* task runs next,
                                   * still done every tick regardless */

    mov r0, sp                    /* r0 = pointer to the context just
                                   * saved -- this task's resume point */
    bl scheduler_switch_from_irq   /* returns r0 = the SP to resume,
                                   * possibly a different task's */
    mov sp, r0

    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr}
    subs pc, lr, #0               /* return from IRQ: pc=lr, cpsr=spsr --
                                   * for a task resumed here for the
                                   * first time, this is indistinguishable
                                   * from a normal exception return, by
                                   * the same fake-initial-frame
                                   * construction Phase 1 established. */

/* void enable_irqs(void) -- vani can't manipulate CPSR directly, so
 * this one-instruction wrapper is the only way to unmask IRQs from
 * vani code. Called once from kernel_main after the timer/interrupt
 * controller are fully configured -- never before, since an IRQ
 * arriving before that setup completes would dispatch into a timer
 * state that was never armed. */
.global enable_irqs
enable_irqs:
    cpsie i
    bx lr
