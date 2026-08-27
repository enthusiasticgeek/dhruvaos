/* Dhruva Phase 2 -- IRQ entry/exit (ARM32), now with real preemption.
 *
 * Step A (BUG-229 fixed, tick delivery proven) always returned to
 * whatever was interrupted. Step B let the timer tick actually switch
 * which task runs. This version fixes a real bug Step B's simple
 * 2-task round robin never exercised: EVERY task in this scheduler
 * runs in SVC mode with its own dedicated per-task stack (that's what
 * makes task_sleep_ticks's plain `bl`-based context switch work at
 * all), but IRQ mode has its OWN separate banked sp, fixed at boot to
 * a small shared scratch stack (_irq_stack_top, boot/rpi1/link.ld).
 * The first version of this file built its saved-context frame with
 * `stmdb sp!` while still in IRQ mode -- meaning that frame lived on
 * the shared IRQ stack, not on the interrupted task's own stack. That
 * "worked" as long as the interrupted task always happened to be the
 * one immediately resumed (Step B's round robin, and every task here
 * that always voluntarily calls task_sleep_ticks before any tick can
 * catch it running). It broke the instant a task was ever actually
 * caught running by a real hardware tick and something ELSE was
 * scheduled next -- the ONLY task that ever happens to in this demo is
 * idle (every other task always sleeps itself before the next tick
 * arrives): idle's "saved sp" ended up pointing into the shared IRQ
 * stack, which the very next interrupt's own entry sequence
 * unconditionally overwrites, and worse, the mismatched sp_irq left
 * dangling after switching to some OTHER task's frame meant the IRQ
 * stack pointer itself drifted into whatever task's memory happened
 * to be resumed. Found by instrumenting the scheduler with raw UART
 * debug prints (dbg_putc et al., since this bug predates having any
 * reliable print path once it triggers) and noticing sp_table[idle]
 * held an address nowhere near idle's actual allocated stack.
 *
 * Fix: stage the raw register dump on the IRQ stack exactly as
 * before (harmless -- it's popped back off within a few instructions,
 * before anything else can reuse that space), then relocate it onto
 * the interrupted task's REAL stack by switching to SVC mode with the
 * `cps` instruction (ARMv6+, mode-only switch -- does not touch the
 * I/F mask bits, so IRQs stay masked throughout) and copying it there.
 * From that point on, everything -- irq_dispatch, scheduler_switch_
 * from_irq, and the final restore of whichever task gets picked next
 * -- runs genuinely in SVC mode using the real per-task stack, which
 * is exactly what task_sleep_ticks already does for its own voluntary
 * switches. The two paths are now consistent: `sp_table` entries are
 * ALWAYS pointers into a real per-task stack, never into IRQ's shared
 * scratch space, regardless of whether a switch was tick-driven or
 * voluntary.
 */

.section ".text"
.global irq_entry
irq_entry:
    sub lr, lr, #4               /* IRQ's lr is 4 ahead of the instruction
                                   * that should actually resume */
    stmdb sp!, {r0-r12, lr}       /* stage on the IRQ stack -- temporary,
                                   * relocated below before anything else
                                   * can touch this memory */
    mrs r0, spsr
    stmdb sp!, {r0, r1}           /* spsr + one padding word = 8 bytes,
                                   * keeping the total 64 bytes -- same
                                   * frame shape task_sleep_ticks builds */

    mov r4, sp                    /* r4 = source (staged frame, on the IRQ
                                   * stack) -- r0-r12 aren't banked, so r4
                                   * survives the mode switch below intact */
    cps #0x13                     /* switch to SVC mode: "sp" now really is
                                   * sp_svc, the interrupted task's own
                                   * stack, wherever it was left -- I stays
                                   * masked, cps's mode-only form doesn't
                                   * touch it */
    sub sp, sp, #64
    mov r5, sp                    /* r5 = destination, on the task's real
                                   * stack */
    mov r6, r5                    /* r6 = keep a copy -- this is the pointer
                                   * every caller downstream actually wants */
    mov r7, #16
irq_relocate_loop:
    ldr r8, [r4], #4
    str r8, [r5], #4
    subs r7, r7, #1
    bne irq_relocate_loop

    cps #0x12                     /* briefly back to IRQ mode, only to undo
                                   * the staging push -- sp_irq must return
                                   * to its _irq_stack_top baseline, or the
                                   * next interrupt entry stages on top of
                                   * leftover clutter instead of a clean
                                   * stack */
    add sp, sp, #64
    cps #0x13                     /* back to SVC mode for good -- everything
                                   * from here on (irq_dispatch, the
                                   * scheduler, and the eventual resume) uses
                                   * the real per-task stack, same as
                                   * task_sleep_ticks's own switches */

    mov r0, r6
    bl irq_dispatch               /* ack + reschedule the timer, print --
                                   * unrelated to *which* task runs next,
                                   * still done every tick regardless; a
                                   * plain `bl` works the same from SVC mode
                                   * as it did from IRQ mode. Returns r0=1
                                   * iff this IRQ was a real timer tick (as
                                   * opposed to, e.g., a UART RX interrupt)
                                   * -- see irq_dispatch's own comment for
                                   * why scheduler_switch_from_irq needs to
                                   * know this. r9 stashes it across the
                                   * `mov r0, r6` below: r4-r11 are callee-
                                   * saved across `bl` per AAPCS, so r9
                                   * survives untouched. */
    mov r9, r0

    mov r0, r6                    /* r0 = pointer to the relocated context --
                                   * this task's real resume point, now
                                   * correctly on ITS OWN stack */
    mov r1, r9                    /* r1 = was_timer_tick, for
                                   * scheduler_switch_from_irq to gate its
                                   * tick_count increment on */
    bl scheduler_switch_from_irq   /* returns r0 = the SP to resume,
                                   * possibly a different task's -- also
                                   * always a real per-task-stack pointer */
    mov sp, r0                     /* sets real sp_svc -- correct now,
                                   * unlike the old IRQ-mode-only version */

    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr}
    subs pc, lr, #0               /* valid from SVC mode exactly as it is
                                   * from IRQ mode: PC=lr, CPSR=SPSR of
                                   * whichever mode issues this -- for a
                                   * task resumed here for the first time,
                                   * indistinguishable from a normal
                                   * exception return, by the same
                                   * fake-initial-frame construction Phase 1
                                   * established. */

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
