/* Dhruva Task #253 Phase 3 (RTOS true-compliance pass, 2026-09-18) --
 * the real SWI syscall trap, letting USR-mode task code reach the
 * genuinely privileged scheduler primitives (task_sleep_ticks_impl,
 * dhruva_mutex_lock_impl/_unlock_impl -- see context_switch.S's own
 * rename comments on each) without itself needing SVC-mode privilege.
 *
 * Architecturally SIMPLER than irq_entry.S/fiq_entry.S: IRQ/FIQ both
 * interrupt a task INVOLUNTARILY, mid-instruction, so they must save
 * and later restore the FULL r0-r12 register set via an explicit
 * 68-byte frame (see irq_entry.S's own header comment for the full
 * "why"). A syscall is different -- it's a VOLUNTARY call, and r0-r12
 * are NOT banked between USR and SVC mode at all (only r13/r14/SPSR
 * are) -- so the moment this handler is entered, r0-r12 ALREADY hold
 * exactly what the USR-mode caller left them as (r7 = syscall number,
 * r0-r3 = the real arguments, by this file's own convention), with no
 * staging/relocation needed at all. The ENTIRE job here is the three
 * things that genuinely ARE lost across the trap:
 *
 *   1. SPSR_svc (this task's own interrupted CPSR) and lr_svc (SWI's
 *      own return-address convention: already correct, unlike IRQ/
 *      FIQ's lr, which needs `sub lr,lr,#4` -- SWI's own lr already
 *      points at the instruction AFTER the `swi`) are both SINGLE
 *      PHYSICAL REGISTERS, banked per MODE not per task. If the
 *      dispatched function blocks (task_sleep_ticks_impl/dhruva_
 *      mutex_lock_impl's own blocked path can suspend this task for
 *      an arbitrary number of OTHER tasks' own ticks/syscalls), both
 *      registers will have been overwritten by every intervening
 *      exception from every OTHER task by the time this one resumes --
 *      exactly the same class of hazard usr_sp_table (context_
 *      switch.S) already solves for r13_usr, solved here the same way
 *      via two more per-task tables (usr_resume_spsr_table/usr_
 *      resume_pc_table, also context_switch.S) captured once at entry,
 *      before dispatch.
 *   2. r13_usr (sp_usr) -- same single-physical-register hazard,
 *      already solved by usr_sp_table/scheduler_restore_usr_sp
 *      (context_switch.S); captured here at entry via the standard
 *      SYS-mode register-bank dip (`cps #0x1F`, shares r13/r14 with
 *      USR but stays privileged -- the same technique irq_entry.S/
 *      fiq_entry.S's own mode-aware capture logic already uses).
 *
 * Whether the dispatched function returns immediately (task_sleep_
 * ticks_impl and dhruva_mutex_lock_impl's OWN fast/uncontended paths,
 * dhruva_mutex_unlock_impl always) or blocks and resumes much later
 * via its own 68-byte frame (whose resume_pc, since it was called via
 * `bl` from right here, correctly points back at swi_return_to_usr
 * below) makes NO difference to the restore logic: `current_task`
 * always correctly reflects whichever task is ACTUALLY resuming by
 * the time swi_return_to_usr runs (set by scheduler_pick_next along
 * the blocked path, or simply unchanged along the fast path), so one
 * shared restore, keyed on current_task, is correct either way -- the
 * exact same "one shared check works for both cases" property
 * scheduler_restore_usr_sp's own header comment already relies on.
 *
 * Does NOT need a USR-vs-SVC mode check the way irq_entry.S/fiq_
 * entry.S's own capture logic does: every real caller today is a USR-
 * mode task (all 10 -- 6 fixed + 4 dynamic -- converted in this same
 * round), and even a hypothetical future SVC-mode caller would behave
 * harmlessly here (the sp_usr capture/restore would just shuffle an
 * unused register; SPSR_svc/lr_svc's own capture-and-restore round
 * trip is correct regardless of what mode they describe, since
 * `movs pc, lr` after `msr spsr_cxsf, <captured value>` faithfully
 * resumes whatever mode was captured -- SVC included). */

.section ".text"

.global swi_entry
swi_entry:
    /* SVC mode now. r7 = syscall number, r0-r3 = args, all directly
     * live from the USR-mode caller (unbanked). lr = lr_svc = correct
     * return address already. SPSR_svc = interrupted USR CPSR. */
    /* r11 (not r4!) for the interrupted-cpsr scratch -- see this
     * file's own trampolines below for the full "why": r4 must pass
     * through this entire function UNTOUCHED, since the trampolines
     * now stash their own true caller-return-address there before
     * ever executing `swi`, and rely on it surviving to restore lr
     * correctly afterward (the exact round-68 true-lr/resume-pc
     * conflation bug, recurring and fixed here -- see the trampolines'
     * own comment for the full incident). r5/r6/r11 are otherwise
     * genuinely free scratch here: nothing above has touched them,
     * and the dispatched functions below are free to clobber them
     * same as any ordinary callee would (only r0-r4 matter to this
     * file's own callers -- r0-r3 as real arguments, r4 as the
     * trampoline's own preserved true-lr). */
    mrs r11, spsr             /* r11 = interrupted cpsr, temporarily */
    mov r5, lr                /* r5 = resume pc, temporarily */

    cps #0x1F                 /* SYS mode -- shares r13/r14 with USR,
                               * still privileged, safe dip (same
                               * technique irq_entry.S/fiq_entry.S's
                               * own mode-aware capture logic uses) */
    mov r6, sp                 /* r6 = live sp_usr, temporarily */
    cps #0x13                  /* back to SVC */

    ldr r8, =current_task
    ldr r8, [r8]
    ldr r9, =usr_resume_spsr_table
    str r11, [r9, r8, lsl #2]
    ldr r9, =usr_resume_pc_table
    str r5, [r9, r8, lsl #2]
    ldr r9, =usr_sp_table
    str r6, [r9, r8, lsl #2]

    /* Dispatch on r7 (syscall number). Each stub calls the real
     * privileged implementation directly (legal now -- we're in SVC
     * mode) and falls through to the shared restore below; for the
     * two functions with a blocking path, control may instead arrive
     * at swi_return_to_usr much later via that function's OWN 68-byte
     * frame (see this file's own header comment) -- either way, the
     * restore below is what actually runs next. */
    cmp r7, #0
    beq swi_do_sleep_ticks
    cmp r7, #1
    beq swi_do_mutex_lock
    cmp r7, #2
    beq swi_do_mutex_unlock
    b swi_return_to_usr        /* unknown syscall number -- no-op,
                               * fall straight through to the restore
                               * rather than doing anything undefined */

swi_do_sleep_ticks:
    bl task_sleep_ticks
    b swi_return_to_usr

swi_do_mutex_lock:
    bl dhruva_mutex_lock
    b swi_return_to_usr

swi_do_mutex_unlock:
    bl dhruva_mutex_unlock
    b swi_return_to_usr

swi_return_to_usr:
    /* current_task here always correctly reflects whichever task is
     * ACTUALLY resuming (see this file's own header comment) -- fresh
     * lookup, not carried in a register across the dispatch above
     * (which may have gone through an arbitrarily long detour via
     * some OTHER task entirely).
     *
     * BUG caught before this ever ran (re-reading this file right
     * after writing it, not live-tested first): the first version of
     * this block used r0/r1 as its own scratch -- but r0 (and r1, for
     * task_sleep_ticks_impl's own i64 return) is exactly where the
     * dispatched function's REAL return value lives at this point,
     * completely unrelated to and never saved/restored around this
     * block's own current_task bookkeeping. Using r0/r1 here would
     * have silently clobbered every syscall's own return value with
     * `current_task`/table contents instead -- every USR-mode caller
     * would see garbage back from task_sleep_ticks/dhruva_mutex_lock/
     * _unlock, indistinguishable from a real logic bug in the caller
     * itself. r2/r3 are the correct scratch choice: never touched by
     * `cps`/`msr`/`movs pc,lr`, and not part of AAPCS's own return-
     * value convention (r0:r1 only, for anything up to 64 bits). */
    ldr r2, =current_task
    ldr r2, [r2]

    ldr r3, =usr_sp_table
    ldr r3, [r3, r2, lsl #2]
    cps #0x1F
    mov sp, r3
    cps #0x13

    ldr r3, =usr_resume_spsr_table
    ldr r3, [r3, r2, lsl #2]
    msr spsr_cxsf, r3

    ldr r3, =usr_resume_pc_table
    ldr lr, [r3, r2, lsl #2]
    movs pc, lr

/* Trampolines -- NOT currently wired into the live call graph (see
 * this file's own bottom-of-header status note): kept under distinct,
 * inert names (task_sleep_ticks_syscall/dhruva_mutex_lock_syscall/
 * dhruva_mutex_unlock_syscall) rather than the real functions' own
 * names (context_switch.S), specifically so nothing calls them yet --
 * a real, separate bug surfaced downstream (SD-driver and shell-
 * dispatch code paths) once this trap was exercised at scale under
 * live QEMU testing, beyond the true-lr bug documented and fixed
 * below, and wiring these back in is deferred until that's found too.
 * Once ready to re-enable: rename these three labels (and their own
 * `.global`s) to task_sleep_ticks/dhruva_mutex_lock/dhruva_mutex_
 * unlock, and rename context_switch.S's own real implementations to
 * _impl (exactly the reverse of this round's own revert) -- everы one
 * of this project's own ~65 existing vani-side call sites (kernel_
 * main.vani's own extern "C" fn declarations) needs no changes either
 * way, since they always call by the same plain name regardless of
 * which side of that rename currently owns it. Syscall number in r7
 * (this file's own convention, matching swi_entry's own dispatch
 * above), arguments passed through completely unchanged in r0-r3.
 *
 * REAL BUG found and fixed here, live-tested (task #253 Phase 3,
 * 2026-09-18) -- the exact round-68 true-lr/resume-pc conflation bug
 * (see irq_entry.S's own header comment for that original incident),
 * recurring because the first version of this file didn't account for
 * it: taking an SWI exception from SVC mode (true whenever a task that
 * STAYS in SVC mode, like every task except IDLE today, calls one of
 * these trampolines) reuses the SAME physical lr_svc/SPSR_svc this
 * trampoline's OWN `bl`-based entry already occupied -- the CPU
 * itself, as part of taking the exception, overwrites lr_svc with the
 * SWI's own return address (this trampoline's own `bx lr` line) BEFORE
 * any software (including swi_entry's own capture logic) ever runs, so
 * the trampoline's real caller-return-address is unrecoverably gone by
 * the time swi_entry.S could try to save it. swi_return_to_usr's own
 * `movs pc, lr` then loads the STORED resume address into lr for the
 * jump -- correct for the PC, but that SAME instruction also becomes
 * this trampoline's own live `lr` from that point on, permanently
 * replacing whatever it should have been for the trampoline's own
 * final `bx lr` (task A's real original caller) -- exactly r14==pc,
 * self-loop territory. Invisible for task_d/IDLE (USR mode): lr_usr is
 * a genuinely SEPARATE banked register, untouched by an SVC exception,
 * so it naturally survives -- which is exactly why this bug was
 * missed originally and only surfaced once tasks that STAY in SVC
 * mode (a-f) started actually calling these trampolines live.
 *
 * Fixed the same way irq_entry.S/fiq_entry.S already fix the identical
 * class of problem: stash the trampoline's own TRUE lr into r4 (r0-r12
 * are never banked/touched by the SWI trap itself, in EITHER USR or
 * SVC mode, so r4 survives the whole round trip intact regardless)
 * BEFORE the trap, and explicitly restore it into lr afterward, rather
 * than trusting whatever physical lr happens to hold post-trap. r4 is
 * AAPCS callee-saved -- pushed/popped around the whole body, since
 * these are called directly from vani-compiled code that may have a
 * live value there. */
.global task_sleep_ticks_syscall
task_sleep_ticks_syscall:
    push {r4}
    mov r4, lr
    mov r7, #0
    swi #0
    mov lr, r4
    pop {r4}
    bx lr

.global dhruva_mutex_lock_syscall
dhruva_mutex_lock_syscall:
    push {r4}
    mov r4, lr
    mov r7, #1
    swi #0
    mov lr, r4
    pop {r4}
    bx lr

.global dhruva_mutex_unlock_syscall
dhruva_mutex_unlock_syscall:
    push {r4}
    mov r4, lr
    mov r7, #2
    swi #0
    mov lr, r4
    pop {r4}
    bx lr
