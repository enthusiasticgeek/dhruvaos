/* Dhruva Phase 2 -- IRQ entry/exit (ARM32).
 *
 * Genuinely different from Phase 1's cooperative yield_now: a hardware
 * interrupt can land on ANY instruction boundary, so unlike a normal
 * function call -- where AAPCS guarantees the caller already saved
 * anything it cares about in the caller-saved registers -- NOTHING
 * about the interrupted code's register state can be assumed dead.
 * r0-r3 and r12 must be saved here explicitly; r4-r11 don't need to be,
 * because `bl irq_dispatch` below calls a normal AAPCS-compliant
 * function, and AAPCS already guarantees any well-behaved callee
 * preserves r4-r11 across its own execution -- that's the same
 * guarantee every other function call in this whole codebase already
 * relies on, not a new assumption specific to interrupts.
 *
 * ARM IRQ mode has its own banked r13(sp)/r14(lr), set up once in
 * boot.S, so entering IRQ mode doesn't disturb whatever stack the
 * interrupted code was using. This first cut of the handler does all
 * its work on that small dedicated IRQ stack and always returns to
 * wherever it interrupted -- it does not yet switch tasks. Real
 * preemption (the IRQ handler deciding a *different* task should run
 * next) needs a bigger redesign of this file, deferred until the
 * basic "does an IRQ even arrive and get handled correctly" question
 * is proven first -- same staged approach as Phase 0/1.
 */

.section ".text"
.global irq_entry
irq_entry:
    sub lr, lr, #4              /* IRQ's lr is 4 ahead of the instruction
                                  * that should actually resume */
    stmdb sp!, {r0-r3, r12, lr}  /* 6 words = 24 bytes */
    mrs r0, spsr
    stmdb sp!, {r0, r1}          /* spsr + one padding word = 8 bytes,
                                  * keeping the total 32 bytes -- AAPCS
                                  * requires 8-byte stack alignment at
                                  * any call boundary, and 7 words (the
                                  * 6 above plus a lone spsr push) would
                                  * leave sp 4 bytes short of that right
                                  * before `bl irq_dispatch` below. */

    bl irq_dispatch

    ldmia sp!, {r0, r1}          /* r0 = spsr; r1 = discarded padding */
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r3, r12, lr}
    subs pc, lr, #0              /* return from IRQ: pc=lr, cpsr=spsr */

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
