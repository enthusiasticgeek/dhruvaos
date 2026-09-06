/* Dhruva round 79 -- interrupt-driven preemption on the Pi 4/5 port,
 * built directly on round 78's proven "two stacks can be swapped
 * between correctly" result but via a genuinely different mechanism:
 * that round's task_switch was a COOPERATIVE, `ret`-based swap of
 * only the AAPCS64 callee-saved registers, invoked by an explicit
 * call. This one is driven entirely by the timer, has to work from
 * INSIDE aarch64_irq_handler's existing full-register-save frame, and
 * resumes via `eret`, not `ret` -- a different, larger frame shape
 * and a genuinely new correctness requirement round 78 never needed
 * to consider.
 *
 * Why the frame had to grow (256 -> 272 bytes): AArch64's `eret`
 * instruction resumes execution using ELR_EL1 (the return PC) and
 * SPSR_EL1 (the return processor state) -- NEITHER of which is part
 * of the general-purpose register file x0-x30 that aarch64_irq_
 * handler already saves. As long as a handler always resumes the
 * SAME context it interrupted (true of every round up through 78),
 * these two registers can be left alone -- untouched, single-buffered
 * hardware state that's still correct by the time `eret` reads it.
 * The MOMENT a handler might resume a DIFFERENT task instead, that
 * stops being true: ELR_EL1/SPSR_EL1 must become PART of each task's
 * own saved frame, explicitly saved on entry and explicitly restored
 * from whichever frame `sp` ends up pointing at before `eret` --
 * otherwise a resumed task would resume at the LAST-INTERRUPTED
 * task's PC, not its own. (This is the AArch64-shaped version of the
 * exact lesson Pi 1's own boot/irq_entry.S already learned the hard
 * way, in ARM32 terms, for its own true-lr-vs-resume-pc conflation
 * bug -- see that file's own header comment. Different register,
 * same underlying principle: a value that's "just always correct" for
 * a same-context resume can silently stop being correct the moment
 * cross-context resumption becomes possible.)
 *
 * SPSR_EL1's value (0x60000345) is NOT hand-derived from the ARM ARM
 * -- it was captured LIVE from a real timer interrupt during round
 * 79's own investigation (a temporary debug print inside aarch64_
 * irq_handler, since ELR_EL1/SPSR_EL1 are only meaningful while an
 * exception is live, removed once captured): M[3:0]=0b0101 (EL1h,
 * matching boot.S's own EL3->EL1 drop target), DAIF=0b1101 (D/A/F
 * masked, I unmasked -- exactly matching boot.S's `msr daifclr, #2`,
 * which clears only the I bit). Used verbatim for every fake frame so
 * a freshly "resumed" task starts with interrupts enabled the same
 * way any genuinely-running task already does -- otherwise it could
 * never itself be preempted again.
 *
 * Round 80 -- generalized from round 79's hardcoded 2-task toggle to
 * NUM_TASKS-way round robin (3 tasks: task_a/b/c), the natural next
 * increment mirroring Pi 1's own historical arc (2-task round robin
 * -> N fixed-priority tasks -> priority ceiling protocol -> general
 * task-creation API) -- still no priorities, still exactly the same
 * proven switch mechanism, just a modulo counter instead of a single
 * toggle bit. current_task / pt_sp_table: index 0..NUM_TASKS-1 are
 * the real tasks, index NUM_TASKS is boot. preempt_init seeds
 * current_task=NUM_TASKS (boot) -- not .bss's own zero default, which
 * would incorrectly mean "task_a" and cause the FIRST real switch to
 * save boot's own interrupted frame into task_a's slot (clobbering
 * its carefully-built fake frame) instead of boot's own. boot's slot
 * is populated implicitly, not by an explicit init call: the very
 * first timer tick's own rpi4_preempt_switch call saves whatever
 * boot's real sp happened to be (deep inside its own `wfi` spin) into
 * pt_sp_table[NUM_TASKS] as a natural side effect of "always save
 * current before deciding next" -- exactly the same mechanism that
 * later saves any task's own frame on every subsequent tick. No
 * special one-time "bootstrap the first switch" code exists anywhere
 * in this file; the general case already covers it.
 */
.section ".bss"
.align 4
/* Starts at 0 (.bss's own zero default -- a nonzero initializer isn't
 * allowed in .bss) but preempt_init explicitly overwrites this to
 * NUM_TASKS (boot) before returning, well before the timer is ever
 * armed, so the "really 0 until then" window is never observable. */
current_task: .word 0
.align 4
pt_sp_table: .quad 0, 0, 0, 0
.align 4
pt_a_stack: .space 1024
pt_a_stack_top:
pt_b_stack: .space 1024
pt_b_stack_top:
pt_c_stack: .space 1024
pt_c_stack_top:
.align 4
heartbeat_printed: .word 0
.align 4
/* Round 81 -- voluntary-yield self-test's own dedicated slots,
 * completely separate from pt_sp_table/current_task above (this
 * self-test runs once, standalone, and never touches the timer-
 * driven demo's own state). Index 0=task_x, 1=task_y, 2=the calling
 * (driver) context. */
yv_sp_table: .quad 0, 0, 0
.align 4
yv_x_stack: .space 1024
yv_x_stack_top:
yv_y_stack: .space 1024
yv_y_stack_top:

.section ".text"

.equ PT_FRAME_SIZE, 272
.equ PT_ELR_OFF, 248
.equ PT_SPSR_OFF, 256
.equ NUM_TASKS, 3
.equ PT_BOOT_INDEX, 3

/* i64 preempt_init(void) -- builds all NUM_TASKS fake interrupt-shaped
 * frames and seeds current_task=PT_BOOT_INDEX. Called once from
 * kernel_main_rpi4.vani's own kmain_rpi4_vani, before boot.S ever
 * arms the timer. */
.global preempt_init
preempt_init:
    stp x29, x30, [sp, #-16]!

    movz x2, #0x0345
    movk x2, #0x6000, lsl #16
    adrp x3, pt_sp_table
    add x3, x3, :lo12:pt_sp_table

    ldr x0, =pt_a_stack_top
    sub x0, x0, #PT_FRAME_SIZE
    adr x1, preempt_task_a_entry
    str x1, [x0, #PT_ELR_OFF]
    str x2, [x0, #PT_SPSR_OFF]
    str x0, [x3, #0]

    ldr x0, =pt_b_stack_top
    sub x0, x0, #PT_FRAME_SIZE
    adr x1, preempt_task_b_entry
    str x1, [x0, #PT_ELR_OFF]
    str x2, [x0, #PT_SPSR_OFF]
    str x0, [x3, #8]

    ldr x0, =pt_c_stack_top
    sub x0, x0, #PT_FRAME_SIZE
    adr x1, preempt_task_c_entry
    str x1, [x0, #PT_ELR_OFF]
    str x2, [x0, #PT_SPSR_OFF]
    str x0, [x3, #16]

    mov w4, #PT_BOOT_INDEX
    adrp x5, current_task
    add x5, x5, :lo12:current_task
    str w4, [x5]

    ldp x29, x30, [sp], #16
    ret

/* i64 rpi4_preempt_switch(uint64_t current_sp, uint64_t force_boot)
 * Called from boot/rpi4/vectors.S's own irq_timer branch, AFTER
 * rpi4_handle_timer_irq has already done its tick-counting/printing/
 * halt-vs-rearm decision -- force_boot is that decision's own return
 * value (1 on the halting tick, 0 otherwise), not computed here.
 * Always saves current_sp into whichever slot current_task currently
 * names, THEN decides the next slot: force_boot=1 always goes to
 * PT_BOOT_INDEX and stays there permanently (nothing ever
 * un-disables the timer, so no interrupt will ever call this again
 * after); otherwise advances 0->1->2->0->... (round robin), with
 * "was boot" also going to 0 -- the one-time transition into the
 * demo, reached implicitly rather than via an explicit start call.
 * Returns the next slot's saved sp, which the caller loads into sp
 * before restoring ELR_EL1/SPSR_EL1/x0-x30 and `eret`-ing into it. */
.global rpi4_preempt_switch
rpi4_preempt_switch:
    adrp x2, current_task
    add x2, x2, :lo12:current_task
    ldr w3, [x2]

    adrp x4, pt_sp_table
    add x4, x4, :lo12:pt_sp_table
    lsl x5, x3, #3
    str x0, [x4, x5]

    cbnz x1, .Lpt_force_boot
    cmp w3, #PT_BOOT_INDEX
    b.eq .Lpt_from_boot            /* was boot -> start at task 0 */
    add w3, w3, #1
    cmp w3, #NUM_TASKS
    b.ne .Lpt_store_next           /* no wrap needed */
    mov w3, #0                     /* wrapped past the last task */
    b .Lpt_store_next
.Lpt_from_boot:
    mov w3, #0
    b .Lpt_store_next
.Lpt_force_boot:
    mov w3, #PT_BOOT_INDEX
.Lpt_store_next:
    str w3, [x2]
    lsl x5, x3, #3
    ldr x0, [x4, x5]
    ret

/* i64 heartbeat_already_printed(void) -- returns the OLD value of a
 * one-shot flag, then sets it to 1. Lets boot.S's own heartbeat_loop
 * (called every wfi wakeup, of which there are many over this
 * kernel's lifetime) print a "boot genuinely resumed" message exactly
 * once, the first (and only) time control actually reaches that point
 * again after the preemption demo's final tick switches back to
 * boot -- see kernel_main_rpi4.vani's own rpi4_heartbeat_tick for the
 * full reasoning on why this is a real, checkable signal and not just
 * "didn't crash." */
.global heartbeat_already_printed
heartbeat_already_printed:
    adrp x0, heartbeat_printed
    add x0, x0, :lo12:heartbeat_printed
    ldr w1, [x0]
    mov w2, #1
    str w2, [x0]
    mov x0, x1
    ret

/* Round 81 -- a genuine VOLUNTARY switch, through the exact same
 * eret-based frame shape rounds 79/80 use for involuntary
 * (timer-driven) preemption -- proves the two are interoperable, not
 * two disconnected mechanisms. Different from round 78's own
 * cooperative task_switch in exactly the way that round's own header
 * comment already anticipated it would need to be for this: that one
 * saved/restored only the AAPCS64 callee-saved registers and resumed
 * via `ret`; this one builds a FULL 272-byte interrupt-shaped frame
 * (all of x0-x30 plus ELR_EL1/SPSR_EL1) and resumes via `eret`, so
 * ANY of these slots -- whether populated by a genuine timer
 * interrupt or by this function -- can be resumed by the exact same
 * shared vectors.S `irq_restore` code.
 *
 * `eret` does not require the CPU to currently be handling a real
 * hardware exception -- it only reads ELR_EL1/SPSR_EL1 and acts on
 * them, so setting them from ordinary code and then executing `eret`
 * is a legitimate, if unusual-looking, way to "return" into a
 * different context. This is the first time this project relies on
 * that specific property.
 *
 * i64 preempt_generic_switch(uint64_t *save_slot, uint64_t *load_slot)
 * x0/x1 are only READ by the register-save block below (stp writes
 * memory, never touches the source registers) -- their true values
 * land safely in the new frame at [sp,#0] before anything reuses x0/
 * x1 as scratch, so nothing here is lost by the time they're
 * repurposed to compute *save_slot/*load_slot. Resume PC (ELR_EL1)
 * is this call's own return address (x30 at entry) -- exactly what
 * `ret` would have used, had this been round 78's cooperative
 * version instead. */
.global preempt_generic_switch
preempt_generic_switch:
    sub sp, sp, #PT_FRAME_SIZE
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    mov x2, x30
    movz x3, #0x0345
    movk x3, #0x6000, lsl #16
    stp x2, x3, [sp, #PT_ELR_OFF]

    mov x2, sp
    str x2, [x0]                   /* *save_slot = this frame's sp */
    ldr x0, [x1]                   /* x0 = *load_slot */
    mov sp, x0
    b irq_restore                  /* shared with vectors.S -- restores
                                     * ELR_EL1/SPSR_EL1/x0-x30 from
                                     * whatever frame sp now points at,
                                     * then `eret`. */

/* i64 yv_init(void) -- builds task_x's and task_y's fake
 * interrupt-shaped frames for the voluntary-yield self-test. Called
 * once from kernel_main_rpi4.vani's own preempt_yield_self_test,
 * completely independent of preempt_init/pt_sp_table above. */
.global yv_init
yv_init:
    stp x29, x30, [sp, #-16]!

    movz x2, #0x0345
    movk x2, #0x6000, lsl #16
    adrp x3, yv_sp_table
    add x3, x3, :lo12:yv_sp_table

    ldr x0, =yv_x_stack_top
    sub x0, x0, #PT_FRAME_SIZE
    adr x1, preempt_yield_task_x_entry
    str x1, [x0, #PT_ELR_OFF]
    str x2, [x0, #PT_SPSR_OFF]
    str x0, [x3, #0]

    ldr x0, =yv_y_stack_top
    sub x0, x0, #PT_FRAME_SIZE
    adr x1, preempt_yield_task_y_entry
    str x1, [x0, #PT_ELR_OFF]
    str x2, [x0, #PT_SPSR_OFF]
    str x0, [x3, #8]

    ldp x29, x30, [sp], #16
    ret

.global yv_x_sp_addr
yv_x_sp_addr:
    adrp x0, yv_sp_table
    add x0, x0, :lo12:yv_sp_table
    ret

.global yv_y_sp_addr
yv_y_sp_addr:
    adrp x0, yv_sp_table
    add x0, x0, :lo12:yv_sp_table
    add x0, x0, #8
    ret

.global yv_driver_sp_addr
yv_driver_sp_addr:
    adrp x0, yv_sp_table
    add x0, x0, :lo12:yv_sp_table
    add x0, x0, #16
    ret
