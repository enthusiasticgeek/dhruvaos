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
    /* Round 68 -- ROOT CAUSE FOUND AND FIXED for the "still-open task_f
     * runtime-trap bug" (docs/TODO.md, context_switch.S's own task_
     * sleep_ticks comment): the saved-context frame's single "lr" word
     * used to serve TWO different purposes at once -- "the value to
     * restore into r14" and "the address to resume execution at" --
     * and for an INTERRUPT-driven switch (unlike a voluntary task_
     * sleep_ticks/dhruva_mutex_lock switch, where those two things are
     * legitimately the same value) these are NOT the same thing. The
     * interrupted task's TRUE r14 (whatever function it was executing
     * was itself going to `bx lr` back to, e.g. its own caller) was
     * NEVER actually saved anywhere -- it just sat in the physical
     * lr_svc register, banked and untouched right up until `bl irq_
     * dispatch`/`bl scheduler_switch_from_irq` below (real calls,
     * running in SVC mode after the `cps #0x13` switch) overwrote it
     * with THEIR OWN return addresses. At restore, `subs pc, lr, #0`
     * used that one clobbered-then-repurposed slot as both the new r14
     * AND the jump target -- so after resuming, r14 always equals pc.
     * Invisible for ordinary vani-compiled functions (their own
     * `push{fp,lr}`/`pop{fp,pc}` prologue saves lr to THEIR OWN stack
     * frame at entry, independent of the live register) -- but this
     * project has ~300 hand-written two-instruction `ldr/str ...; bx
     * lr` accessor leaves (every `*_get`/`*_set` in every `boot/*_
     * state.S` file, `buf_read_u32`/`buf_write_u32` among them) that
     * rely on the LIVE r14 surviving a preemption. If a timer/UART
     * interrupt lands exactly inside one of these, it resumes with r14
     * == its own entry address: the single `ldr`/`str` re-executes
     * fine, then `bx lr` jumps back into itself instead of returning,
     * repeatedly reading whatever it just loaded as a NEW base pointer
     * (`buf_read_u32`'s `r0 = *(u32*)(r0+r1)`, r1 fixed) until it
     * dereferences something unmapped -- a real hardware Data Abort
     * with a "wild-looking" address that's actually just wherever that
     * chase ended up. Matches every captured crash this investigation
     * found: the offset is always small/plausible (the real original
     * offset), it always lands in one of these bare leaves, and a
     * live-captured saved frame showed lr == pc == buf_read_u32's own
     * entry address immediately before the fault.
     *
     * Fix: save the interrupted task's TRUE lr_svc SEPARATELY from the
     * resume PC, growing the frame from 16 to 17 words (64 -> 68
     * bytes: spsr, pad, r0-r12, true_lr, resume_pc), and restore with
     * ARM's standard `ldmia {..., lr, pc}^` exception-return idiom,
     * which loads r14 and pc from two INDEPENDENT words (and restores
     * CPSR from SPSR atomically, same as the `subs pc,lr,#0` this
     * replaces) instead of conflating them into one. task_sleep_ticks/
     * dhruva_mutex_lock/prepare_stack_common/start_multitasking all
     * updated to the same 17-word layout for consistency -- for their
     * voluntary/initial-launch cases true_lr and resume_pc are
     * legitimately the same value, so they just store it twice. */
    sub lr, lr, #4                /* IRQ's lr is 4 ahead of the instruction
                                   * that should actually resume */
    stmdb sp!, {r0-r12, lr}       /* stage on the IRQ stack -- temporary,
                                   * relocated below before anything else
                                   * can touch this memory. This "lr" is
                                   * lr_irq (resume PC), NOT the
                                   * interrupted task's own r14 -- see
                                   * above. */
    mrs r0, spsr
    stmdb sp!, {r0, r1}           /* spsr + one padding word = 8 bytes;
                                   * 64 bytes staged total, UNCHANGED --
                                   * the true-lr word is appended
                                   * separately below, after relocation,
                                   * once we're back in SVC mode and can
                                   * actually read it. */

    mov r4, sp                    /* r4 = source (staged frame, on the IRQ
                                   * stack) -- r0-r12 aren't banked, so r4
                                   * survives the mode switch below intact */
    cps #0x13                     /* switch to SVC mode: "sp" now really is
                                   * sp_svc, the interrupted task's own
                                   * stack, wherever it was left -- I stays
                                   * masked, cps's mode-only form doesn't
                                   * touch it. Critically, "lr" here now
                                   * means lr_svc: the interrupted task's
                                   * TRUE r14, completely untouched since
                                   * the moment it was interrupted (banking
                                   * means the mode switch itself can't
                                   * have changed it) -- grab it immediately,
                                   * before the first `bl` below gets a
                                   * chance to overwrite it. */
    mov r2, lr                    /* r2 = interrupted task's TRUE r14 */
    sub sp, sp, #68                /* 17-word frame now, not 16 */
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
    /* The 16 words just copied verbatim end with the staged "lr" (=
     * resume PC) at [r6, #60] -- correct content, wrong slot for the
     * new layout, where position 60 must hold the TRUE lr and the
     * resume PC moves to the new 17th word, position 64 (== r5, which
     * the loop above left pointing exactly one word past the copied
     * block). Swap them into their real homes. */
    ldr r9, [r6, #60]              /* r9 = resume PC (currently at 60) */
    str r9, [r5]                    /* position 64 = resume PC */
    str r2, [r6, #60]               /* position 60 = TRUE lr */

    cps #0x12                     /* briefly back to IRQ mode, only to undo
                                   * the staging push -- sp_irq must return
                                   * to its _irq_stack_top baseline, or the
                                   * next interrupt entry stages on top of
                                   * leftover clutter instead of a clean
                                   * stack */
    add sp, sp, #64                /* staging itself is still exactly 64
                                   * bytes -- UNCHANGED, only the
                                   * RELOCATED destination frame grew */
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
                                   * survives untouched. This `bl` (and the
                                   * next) is exactly what used to clobber
                                   * lr_svc before the true value was ever
                                   * saved -- now harmless, since r2's copy
                                   * is already safely in the relocated
                                   * frame by this point. */
    mov r9, r0

    mov r0, r6                    /* r0 = pointer to the relocated context --
                                   * this task's real resume point, now
                                   * correctly on ITS OWN stack */
    mov r1, r9                    /* r1 = was_timer_tick, for
                                   * scheduler_switch_from_irq to gate its
                                   * tick_count increment on */
    bl scheduler_switch_from_irq   /* returns r0 = the SP to resume,
                                   * possibly a different task's -- also
                                   * always a real per-task-stack pointer,
                                   * now a 68-byte frame */
    mov sp, r0                     /* sets real sp_svc -- correct now,
                                   * unlike the old IRQ-mode-only version */

    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr, pc}^    /* restores r0-r12 AND the TRUE lr from
                                   * two INDEPENDENT words, then jumps to
                                   * the (separately-stored) resume PC --
                                   * the caret suffix, with pc in the
                                   * register list, additionally restores
                                   * CPSR from SPSR atomically, same
                                   * exception-return semantics as the
                                   * `subs pc,lr,#0` this replaces, but
                                   * without conflating lr and pc into the
                                   * same value. Valid from SVC mode
                                   * exactly as it would be from IRQ mode
                                   * -- for a task resumed here for the
                                   * first time, indistinguishable from a
                                   * normal exception return, by the same
                                   * fake-initial-frame construction Phase
                                   * 1 established (see prepare_stack_
                                   * common, context_switch.S). */

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
