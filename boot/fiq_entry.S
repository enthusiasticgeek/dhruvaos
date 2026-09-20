/* Dhruva Task #246 (RTOS true-compliance pass, 2026-09-18) -- FIQ entry
 * for the timer tick, BCM2835's one real interrupt-priority mechanism.
 *
 * Mirrors irq_entry.S's own save/relocate/dispatch/restore shape as
 * closely as possible (same 17-word frame layout, same scheduler_
 * switch_from_irq/scheduler_pick_next call convention, same final
 * `ldmia ...^` restore) -- but the register-banking rules are
 * genuinely different for FIQ, and getting that difference wrong is
 * exactly the kind of mistake this project's own crash history (round
 * 68's true-lr bug, scheduler_pick_next's own documented incident, and
 * this same session's own subagent incident: unverified assembly in
 * this exact class of code, found broken, reverted) warns against, so
 * it's worth spelling out precisely before the code itself:
 *
 * IRQ mode banks ONLY r13(sp)/r14(lr) -- r0-r12 are the SAME physical
 * registers as whatever was interrupted (SVC mode, always, in this
 * project). irq_entry.S exploits this: it can `stmdb sp!, {r0-r12,lr}`
 * immediately, using the INTERRUPTED task's own live r0-r12 directly,
 * then relocate that staged block onto the task's real stack after
 * switching to SVC mode.
 *
 * FIQ mode banks r8-r14 -- FIVE more registers than IRQ. r8-r12 here
 * are FIQ's OWN private copies (a genuine ARM feature specifically so
 * a fast interrupt handler never needs to save/restore them) -- they
 * are NOT the interrupted task's r8-r12, and the moment execution
 * leaves FIQ mode (e.g. `cps` to SVC), any register number 8-12 stops
 * referring to FIQ's copies and starts referring to that OTHER mode's
 * own r8-r12 instead. Two direct consequences, both load-bearing for
 * this file's own structure below:
 *   1. Only r0-r7 need to be staged/relocated here -- r8-r12 are
 *      FIQ's own, safe to use freely as scratch, and simply don't
 *      exist as "the interrupted task's r8-r12" until SVC mode is
 *      entered, at which point they ARE that, live, already exactly
 *      where they need to be (no relocation needed for those five).
 *   2. Anything computed into r8-r12 (or FIQ's own sp/lr) is LOST the
 *      instant `cps` changes mode away from FIQ -- only r0-r7 survive
 *      a mode transition intact. Every value that needs to cross the
 *      `cps #0x13` below (the staged-frame pointer, the interrupted
 *      cpsr+resume-pc) is deliberately carried in r0-r3, never r8-r12.
 *
 * FIQ also has a real, architecture-guaranteed safety property IRQ
 * does not: taking an FIQ exception automatically masks BOTH further
 * FIQs (so this handler can never itself be re-entered) AND further
 * IRQs (so it can never be preempted by ordinary IRQ-level work
 * either) -- the CPU does this for us, no explicit `cpsid` needed on
 * entry here, unlike irq_entry.S's own new `cpsid f` (that one exists
 * for the OPPOSITE direction: protecting IRQ-level code, which does
 * NOT get F auto-masked, from being preempted by this FIQ). The
 * matching real correctness work this asymmetry required -- masking
 * FIQ at every existing SVC-mode scheduler-state critical section
 * (context_switch.S: task_sleep_ticks, dhruva_mutex_lock/_unlock,
 * task_create, `cpsid i` -> `cpsid if`) -- is already done; this
 * handler's own atomicity comes for free from the hardware. */

/* ROUND 2026-09-19 (task #253, real-WCET investigation): 2-word scratch
 * for the USR-mode sp_usr/lr_usr capture below -- see irq_entry.S's
 * own matching `irq_usr_capture_scratch` comment for the full "why"
 * (single-instruction user-register STM instead of a `cps` dip,
 * confirmed against real Linux's `vector_swi`). Dedicated to this file
 * for the same reason irq_entry.S's own copy is dedicated to it: IRQ
 * and FIQ auto-mask each other (this file's own header comment), so
 * neither can ever preempt the other's use of its own scratch. */
.section ".bss"
.align 2
fiq_usr_capture_scratch:
    .word 0, 0

.section ".text"
.global fiq_entry
fiq_entry:
    sub lr, lr, #4                  /* FIQ's own lr is 4 ahead of the
                                     * instruction that should actually
                                     * resume -- same convention, same
                                     * reasoning, as irq_entry.S's own
                                     * `sub lr, lr, #4`. */

    /* Stage the interrupted context's real r0-r7 (the genuinely SHARED
     * set) onto FIQ's own dedicated stack (sp_fiq, boot/rpi1/link.ld) --
     * temporary, relocated onto the task's real stack below, same
     * stage-then-relocate strategy irq_entry.S uses, just for a
     * different register set. */
    stmdb sp!, {r0-r7}                /* low-to-high in memory: r0,r1,...,r7 */
    mrs r0, spsr                      /* r0 = interrupted cpsr -- r0's own
                                        * real value is already safely
                                        * staged above, free to clobber now */
    mov r1, lr                        /* r1 = resume pc -- same reasoning,
                                        * r1's real value already staged */
    stmdb sp!, {r0, r1}                /* staged block, low-to-high in
                                        * memory from the new sp:
                                        * [spsr, resume_pc, r0,r1,...,r7]
                                        * (10 words total) */
    mov r0, sp                        /* r0 (a SHARED register -- survives
                                        * the mode switch below) = pointer
                                        * to the staged block's base */

    cps #0x13                         /* -> SVC mode. r0 still = staged-
                                        * block pointer (survived, shared
                                        * reg). "lr" here is now lr_svc:
                                        * the interrupted task's TRUE r14,
                                        * completely untouched by anything
                                        * FIQ-side (banking means the mode
                                        * switch itself can't have changed
                                        * it) -- grab it immediately,
                                        * before any `bl` below gets a
                                        * chance to overwrite it, exactly
                                        * mirroring irq_entry.S's own
                                        * `mov r2, lr` at the equivalent
                                        * point. "sp" here is sp_svc: the
                                        * interrupted task's own real
                                        * stack, wherever it was left. */
    /* Task #253 (RTOS true-compliance pass, 2026-09-18): same mode-
     * aware capture irq_entry.S's own equivalent point now does -- if
     * the interrupted context was USR mode (is_usr_mode_task, today
     * only IDLE/task_d), lr_svc is NOT this task's true r14 (it's SVC
     * mode's own banked register, untouched by USR-mode execution);
     * the real value lives in lr_usr instead. Unlike irq_entry.S, spsr
     * isn't live in a register here anymore (it was pushed to the
     * staged block already) -- peek it back from [r0, #0] without
     * disturbing r0 itself (still needed as the staged-block source
     * pointer below). r1/r3/r5 are free scratch at this exact point
     * (r1's real value already staged to memory; r3/r5 not assigned
     * their own real purpose -- frame base / second frame-base copy --
     * until immediately after this block) -- r0, r2, r4, and r8-r12
     * (already live as the interrupted task's own real r8-r12 the
     * instant `cps #0x13` above executed, per this file's own header
     * comment) must NOT be touched here. */
    ldr r1, [r0, #0]        /* r1 = staged spsr (peek, r0 untouched) */
    and r3, r1, #0x1F
    cmp r3, #0x10
    bne fiq_entry_true_lr_svc
    /* Single-instruction user-register STM captures BOTH sp_usr and
     * lr_usr at once, no mode switch -- see this file's own top-of-file
     * comment on fiq_usr_capture_scratch for the full "why". r1/r3/r5
     * used as scratch here, same set the original `cps`-based version
     * used -- r2 written exactly once, at the very end, with its real
     * final value (true_lr), matching this block's own established
     * register discipline. */
    ldr r1, =fiq_usr_capture_scratch
    stmia r1, {sp, lr}^        /* [r1+0]=sp_usr, [r1+4]=lr_usr */
    ldr r3, =current_task
    ldr r3, [r3]
    ldr r5, =usr_sp_table
    add r5, r5, r3, lsl #2     /* r5 = &usr_sp_table[current_task] */
    ldr r3, [r1]                /* r3 = sp_usr value */
    str r3, [r5]                 /* usr_sp_table[current_task] = sp_usr */
    ldr r2, [r1, #4]             /* r2 = lr_usr value = true_lr (final
                                  * destination) */
    b fiq_entry_true_lr_done
fiq_entry_true_lr_svc:
    mov r2, lr                 /* r2 = interrupted task's TRUE r14 --
                                * unchanged SVC-mode case, exactly as
                                * this file always did before this
                                * round */
fiq_entry_true_lr_done:
    sub sp, sp, #68                    /* allocate the 17-word (68-byte)
                                        * frame on the task's REAL stack --
                                        * same layout as everywhere else in
                                        * this project: spsr, pad, r0-r12,
                                        * true_lr, resume_pc */
    mov r3, sp                        /* r3 = destination frame base (F) */
    mov r6, r3                        /* r6 = second copy of F -- this is
                                        * what irq_dispatch/scheduler_
                                        * switch_from_irq actually want,
                                        * and what gets returned as the
                                        * "resume sp" eventually, exactly
                                        * mirroring irq_entry.S's own r6
                                        * usage */

    /* Copy the 10 staged words (spsr, resume_pc, r0..r7) from FIQ's
     * staging area into their real homes in the new frame. r4 is used
     * purely as a relay register for each word -- its OWN "real" value
     * (the interrupted task's r4) is one of the 8 words being relayed
     * THROUGH it, never confused with the relay itself, since each
     * load is immediately followed by its own store before the next
     * load overwrites r4 again (same one-word-at-a-time relay pattern
     * irq_entry.S's own relocate loop uses with its own r8). */
    ldr r4, [r0], #4                  /* staged spsr */
    str r4, [r3, #0]                  /* F+0 = spsr */
    ldr r4, [r0], #4                  /* staged resume_pc */
    str r4, [r3, #64]                 /* F+64 = resume_pc */
    ldr r4, [r0], #4                  /* real r0 */
    str r4, [r3, #8]                  /* F+8 = r0 */
    ldr r4, [r0], #4                  /* real r1 */
    str r4, [r3, #12]
    ldr r4, [r0], #4                  /* real r2 */
    str r4, [r3, #16]
    ldr r4, [r0], #4                  /* real r3 (relayed through r4 --
                                        * does not touch our own pointer
                                        * register r3, which is never the
                                        * TARGET of any load in this
                                        * loop) */
    str r4, [r3, #20]
    ldr r4, [r0], #4                  /* real r4 (this IS our own relay
                                        * register's namesake, but again:
                                        * relayed value, not the register
                                        * itself -- harmless, same as
                                        * every other word here) */
    str r4, [r3, #24]
    ldr r4, [r0], #4                  /* real r5 */
    str r4, [r3, #28]
    ldr r4, [r0], #4                  /* real r6 (relayed -- does not
                                        * touch our own r6, which holds F
                                        * and is never a load target) */
    str r4, [r3, #32]
    ldr r4, [r0], #4                  /* real r7 -- last staged word */
    str r4, [r3, #36]

    str r2, [r3, #60]                 /* F+60 = true_lr (r2, captured
                                        * right after the mode switch) */

    /* r8-r12: no relay needed. We are in SVC mode, nothing has run
     * since the `cps` above that could have touched SVC's own r8-r12
     * -- they ARE, right now, exactly the interrupted task's real
     * r8-r12, still live. Store them directly. */
    add r5, r3, #40                    /* r5 = &F[r8's slot] (F+40) -- r5
                                        * is free scratch here (its own
                                        * real value was already relayed
                                        * and stored above) */
    stmia r5, {r8-r12}                  /* F+40..F+56 = r8,r9,r10,r11,r12,
                                        * in order; `stmia Rn, {..}`
                                        * (no `!`) leaves r5 itself
                                        * unmodified, which is fine, it's
                                        * not needed again */

    /* ROUND 2026-09-18 (verification pass on this file before trusting
     * it): irq_entry.S's own equivalent point does a `cps #0x12; add
     * sp,sp,#64; cps #0x13` dip back into IRQ mode specifically to pop
     * its staging area off sp_irq, "or the next interrupt entry stages
     * on top of leftover clutter instead of a clean stack" (see that
     * file's own comment on this exact step). This file was missing
     * the equivalent step entirely -- without it, sp_fiq would never
     * return to its _fiq_stack_top baseline, and every single FIQ
     * (i.e. every timer tick, effectively continuous) would leak
     * another 40 bytes (this file's own staging size -- 10 words, NOT
     * IRQ's 64/16) permanently off sp_fiq, walking clean off the
     * bottom of the 4KB _fiq_stack_top region (link.ld) after roughly
     * 4096/40 ~= 102 ticks and corrupting whatever memory sits below
     * it (_abort_stack_top, per link.ld's own layout) -- a guaranteed,
     * fast-manifesting crash that would NOT have shown up in any
     * static read of this file's own tail alone, only by directly
     * diff'ing every step against irq_entry.S's real equivalent
     * sequence, which is exactly how this was caught. Same fix,
     * FIQ's own mode value (0x11, not IRQ's 0x12) and staging size. */
    cps #0x11                      /* briefly back to FIQ mode, only to
                                    * undo the staging push -- r0/r3/r6
                                    * (unbanked) survive this dip intact,
                                    * exactly as r4/r5/r6/r7 survive
                                    * irq_entry.S's own equivalent dip;
                                    * r8-r12 become FIQ's own private
                                    * copies again here, harmless, not
                                    * read or written during this dip */
    add sp, sp, #40                 /* pop the 10-word (40-byte) staging
                                    * area back off sp_fiq -- restores it
                                    * to its _fiq_stack_top baseline */
    cps #0x13                      /* back to SVC mode for good */

    /* From here on, this is deliberately IDENTICAL to irq_entry.S's
     * own tail (dispatch + scheduler switch + restore) -- r6 holds the
     * same "pointer to a fully-built 17-word frame on the task's real
     * stack" contract either path produces, so the exact same restore
     * sequence is correct regardless of which exception originally
     * triggered the switch. Duplicated rather than branched-to
     * (irq_entry.S's own equivalent code is not exposed as a separate
     * callable label) -- kept byte-for-byte identical on purpose so a
     * future change to one is easy to notice needs the same change in
     * the other. */
    mov r0, r6
    bl timer_tick_dispatch          /* FIQ is exclusively the timer tick
                                     * (FIQ_CONTROL routes exactly one
                                     * source here) -- always a real
                                     * tick, by construction, so this
                                     * calls timer_tick_dispatch
                                     * directly rather than irq_
                                     * dispatch's own pending-bit check
                                     * (which now only ever looks at
                                     * UART RX, never the timer). Always
                                     * returns 1 (was_timer_tick) --
                                     * see kernel_main.vani's own
                                     * header comment on that function. */
    mov r9, r0                       /* stash across the mov below --
                                      * r4-r11 callee-saved across `bl`
                                      * per AAPCS, r9 survives untouched */

    mov r0, r6
    mov r1, r9
    bl scheduler_switch_from_irq     /* returns r0 = the SP to resume,
                                      * possibly a different task's --
                                      * mode-agnostic (only touches
                                      * memory-resident scheduler state
                                      * plus a tail call to scheduler_
                                      * pick_next), confirmed by reading
                                      * it directly -- works identically
                                      * regardless of which exception
                                      * got us here. */
    mov sp, r0                       /* sets real sp_svc */
    /* Task #253 Phase 3 bug investigation (2026-09-19): same current_
     * task==0-gated diagnostic as task_sleep_ticks_impl's own
     * (context_switch.S) -- checking whether task_a's SECOND
     * involuntary resume (the one that never happens, per this
     * session's own live A/B testing: total system freeze after
     * exactly 2 "HIGH: waking/acquired/released" cycles) is even
     * reaching this FIQ-driven, tick-triggered restore path at all.
     * Placed AFTER `mov sp, r0` above, matching the FIXED (not the
     * original buggy) placement discipline task_sleep_ticks_impl's own
     * diagnostic needed -- doing this BEFORE the sp switch would fault
     * (DACR already switched to the newly-picked task's domain by
     * scheduler_pick_next, while sp would still point at the outgoing
     * task's own stack). Shares that diagnostic's own fire-cap counter
     * (sleep_ticks_diag_fire_count) so the two investigation points'
     * cumulative print cost stays bounded together, not doubled. */
    ldr r1, =current_task
    ldr r1, [r1]
    cmp r1, #0
    bne fiq_resume_diag_skip
    ldr r2, =sleep_ticks_diag_fire_count
    ldr r3, [r2]
    cmp r3, #8
    bge fiq_resume_diag_skip
    add r3, r3, #1
    str r3, [r2]
    ldr r0, =fiq_resume_diag_msg
    bl sched_diag_puts
fiq_resume_diag_skip:
    bl scheduler_restore_usr_sp      /* task #253: no-op unless the task
                                      * about to resume is USR-mode --
                                      * see that function's own header
                                      * comment (context_switch.S) */

    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr, pc}^      /* restores r0-r12 AND the TRUE lr
                                      * from two independent words, then
                                      * jumps to the resume PC, restoring
                                      * CPSR (mode + I + F) from SPSR
                                      * atomically -- same exception-
                                      * return idiom irq_entry.S uses,
                                      * valid from SVC mode exactly as it
                                      * would be from IRQ or FIQ mode. */

/* void enable_fiqs(void) -- vani can't manipulate CPSR directly, so
 * this one-instruction wrapper is the only way to unmask FIQs from
 * vani code, mirroring irq_entry.S's own enable_irqs exactly. Checked
 * (2026-09-18) whether this actually needs a call site: it doesn't,
 * for the same reason enable_irqs itself is declared+defined but
 * never actually called anywhere (grep confirms zero call sites for
 * either). Every fake/resumed task frame in context_switch.S (prepare_
 * stack_common and both wake-from-block paths) stages spsr=0x13 --
 * SVC mode with BOTH the I bit (0x80) and F bit (0x40) already clear
 * -- so start_multitasking's very first restore unmasks IRQ and FIQ
 * together, atomically, the same instant task_a first runs; there is
 * no window where one is unmasked and the other isn't. Kept anyway,
 * same as enable_irqs, as an available primitive matching this
 * project's existing pattern rather than dead code to delete -- see
 * kernel_main.vani's own start_multitasking call-site comment for the
 * IRQ side of this same reasoning. */
.global enable_fiqs
enable_fiqs:
    cpsie f
    mov r0, #0
    mov r1, #0
    bx lr

.section ".rodata"
fiq_resume_diag_msg:
    .asciz "FIQ: task_a resumed (tick-driven)\n"
.section ".text"
