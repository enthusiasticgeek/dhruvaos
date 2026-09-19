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
    /* BUG found+fixed 2026-09-19 (re-wire round, chasing the SD-driver/
     * shell-dispatch crash): taking `swi` auto-masks I (every exception
     * does) but NEVER F -- unlike every other scheduler-critical-section
     * entry point in this project (task_sleep_ticks_impl/dhruva_mutex_
     * lock_impl/_unlock_impl's own `cpsid if`, irq_entry.S's own `cpsid
     * f`), this file had no equivalent, leaving F genuinely unmasked
     * through both of its own `cps #0x1F` SYS-mode register-bank dips
     * below (entry capture here, and swi_return_to_usr's own restore) --
     * live-reachable, not theoretical: dhruva_mutex_lock_impl's own
     * fast/uncontended path restores the FULL original CPSR (`msr
     * cpsr_c, r1`, captured before ITS OWN `cpsid if`) before `bx lr`
     * back into swi_do_mutex_lock, which had F=0 the entire time (this
     * file never touched it) -- so by the time swi_return_to_usr's own
     * dip runs, F is back to unmasked. A real timer tick FIQ landing in
     * either dip window interrupts this task while the CPU is literally
     * IN SYS mode (0x1F) -- a THIRD mode fiq_entry.S's own true-lr mode
     * check (`cmp r3,#0x10` -- USR only) was never built to recognize,
     * only USR (0x10) vs "everything else assumed SVC"; SYS shares its
     * r13/r14 bank with USR, not SVC, so that fallthrough silently reads
     * the wrong physical register as this task's own "true" r14 at the
     * interrupted instant. Fixed here at the root (mask F for this
     * file's entire body, matching every other scheduler-critical-
     * section's own convention) rather than teaching fiq_entry.S a
     * third mode case -- no explicit `cpsie f` needed anywhere below:
     * every exit path here ends by restoring the ORIGINAL full CPSR
     * from a saved SPSR (either this function's own final `msr
     * spsr_cxsf`+`movs pc,lr`, or a dispatched function's own full
     * switch-away `ldmia ...^`), which naturally un-masks F again the
     * same way `cpsid if` elsewhere in this project relies on. */
    cpsid f
    /* SECOND real bug found+fixed here 2026-09-19 (same round as the
     * cpsid f fix above; THIS one, not that one, turned out to be the
     * actual cause of the SD-driver/shell-dispatch crash -- verified by
     * testing the cpsid f fix alone first, which built and ran clean
     * but reproduced the identical crash unchanged, then finding this
     * one and re-testing): r5/r6/r8/r9/r11 were being used as scratch
     * below WITHOUT saving them first -- wrongly reasoned, in the
     * comment this replaces, to be "genuinely free". They are NOT: per
     * AAPCS, r4-r11 are callee-saved, and this function is reached via
     * a plain `bl` from vani-compiled caller code (through the
     * trampolines below) that relies on that guarantee -- the exact
     * same bug class this project has hit before (see sdcard_state.S's
     * own file-level comment: "vani's generated caller code keeps
     * genuinely live values in [r4-r11] across calls on the strength
     * of that guarantee"). The trampolines only save/restore r4 (the
     * true-lr fix above) -- nothing saved r5/r6/r8/r9/r11, so any live
     * value a caller held in one of those across a call to task_sleep_
     * ticks/dhruva_mutex_lock/_unlock was silently destroyed by this
     * function's own bookkeeping before the caller ever got control
     * back. Worse for the two functions with a blocking path: task_
     * sleep_ticks_impl/dhruva_mutex_lock_impl's own 68-byte frame saves
     * "r5/r6/r8/r9/r11" too -- but by the time they run, this function
     * had ALREADY overwritten those registers with its own scratch
     * values, so the corrupted values got faithfully saved and later
     * faithfully RESTORED when the task woke back up -- a corrupted
     * register that only surfaces as a crash much later, whenever that
     * task next actually uses it (exactly matching the observed
     * symptom: a stack/buffer pointer that had decayed to a near-null
     * address, surfacing tens to hundreds of context switches after
     * the actual corruption). Fixed by saving the true originals first
     * and restoring them before ever reaching the dispatch below -- r4
     * (trampoline's own true-lr) and r0-r3/r7 (real arguments/syscall
     * number) are deliberately excluded from this save/restore, exactly
     * as before. */
    push {r5, r8, r9, r11}
    mrs r11, spsr             /* r11 = interrupted cpsr, temporarily */
    mov r5, lr                /* r5 = resume pc, temporarily */

    ldr r8, =current_task
    ldr r8, [r8]
    ldr r9, =usr_resume_spsr_table
    str r11, [r9, r8, lsl #2]
    ldr r9, =usr_resume_pc_table
    str r5, [r9, r8, lsl #2]
    /* BUG found+fixed 2026-09-19 (task #253 Phase 3, converting task_a
     * to USR mode): this usr_sp_table write used to be unconditional --
     * "even a hypothetical future SVC-mode caller would behave
     * harmlessly here (the sp_usr capture/restore would just shuffle an
     * unused register)" (this file's own original header reasoning).
     * That reasoning breaks down the moment a genuinely USR-mode task
     * and an SVC-mode CALLER share the SAME task_index -- exactly
     * kernel_main.vani's own boot-time execution (current_task reads
     * its .bss default, 0, the entire time kernel_main itself is
     * running, before start_multitasking ever hands off) and task_a
     * (also index 0, once converted). Adding dhruva_prio_lock/_unlock
     * as syscalls (see this file's own trampolines below) meant every
     * ordinary boot-time uart_puts call -- NOT just uart_puts_bounded,
     * used throughout self-tests during boot, current_task==0 the
     * whole time -- now traps through here too, unconditionally
     * OVERWRITING usr_sp_table[0] with whatever boot-time sp_usr
     * garbage happened to be live, silently destroying kernel_main's
     * own correct `usr_sp_table_set_at(0, stack_a_usr_top)` seed made
     * moments earlier. Live-reproduced via GDB: task_a's own first
     * instruction faulted with sp_usr==0 (address -8, matching `push`
     * on a null stack) -- traced directly to this write, hit
     * repeatedly by boot-time uart_puts->dhruva_prio_lock calls between
     * the seed and start_multitasking. Fixed by gating this write (and
     * swi_return_to_usr's own matching sp_usr restore below) on is_usr_
     * mode_task[current_task], exactly the same check scheduler_
     * restore_usr_sp already uses -- the spsr/pc tables above stay
     * UNCONDITIONAL (genuinely needed by every caller, USR or SVC, to
     * survive an arbitrarily long nested-preemption detour -- only the
     * sp_usr-specific table was ever meant to be USR-only). */
    /* ROUND 2026-09-19 (task #253, real-WCET investigation): used to
     * unconditionally dip into SYS mode (`cps #0x1F; mov r6,sp; cps
     * #0x13`) to capture sp_usr into r6 BEFORE this gate, even for an
     * SVC-mode caller that will just discard it -- two real mode
     * switches paid on every single syscall regardless of caller mode.
     * Now computes the table address first and, only when actually
     * needed, stores sp_usr straight into memory with ARM's single-
     * instruction user-register STM form (`stmia Rn,{sp}^`, valid
     * because sp is in the list and pc is not, no writeback) -- see
     * scheduler_restore_usr_sp's own header comment (context_switch.S)
     * for the full "why" and the real Linux reference
     * (arch/arm/kernel/entry-common.S's `vector_swi`) this is
     * confirmed against. r6 no longer needed at all -- dropped from
     * the save/restore list below too. */
    ldr r9, =is_usr_mode_task
    ldr r9, [r9, r8, lsl #2]
    cmp r9, #0
    beq swi_entry_skip_usr_sp_capture
    ldr r9, =usr_sp_table
    add r9, r9, r8, lsl #2     /* r9 = &usr_sp_table[current_task] */
    stmia r9, {sp}^            /* store sp_usr directly -- no mode switch */
swi_entry_skip_usr_sp_capture:
    pop {r5, r8, r9, r11}      /* restore the caller's true originals
                               * before the dispatched function (or its
                               * own later-resumed frame) ever sees them
                               * again */

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
    cmp r7, #3
    beq swi_do_prio_lock
    cmp r7, #4
    beq swi_do_prio_unlock
    b swi_return_to_usr        /* unknown syscall number -- no-op,
                               * fall straight through to the restore
                               * rather than doing anything undefined */

swi_do_sleep_ticks:
    bl task_sleep_ticks_impl
    b swi_return_to_usr

swi_do_mutex_lock:
    bl dhruva_mutex_lock_impl
    b swi_return_to_usr

swi_do_mutex_unlock:
    push {r6}
    bl swi_fast_measure_start
    bl dhruva_mutex_unlock_impl
    bl swi_fast_measure_end
    pop {r6}
    b swi_return_to_usr

swi_do_prio_lock:
    push {r6}
    bl swi_fast_measure_start
    bl dhruva_prio_lock_impl
    bl swi_fast_measure_end
    pop {r6}
    b swi_return_to_usr

swi_do_prio_unlock:
    push {r6}
    bl swi_fast_measure_start
    bl dhruva_prio_unlock_impl
    bl swi_fast_measure_end
    pop {r6}
    b swi_return_to_usr

/* Task #253 Phase 3 instrumentation round (2026-09-19): real,
 * hardware-measured cost of the SWI trap's own fast round trip -- see
 * context_switch.S's own swi_fast_worst_us/total_us/count header
 * comment for the full "why" (only #2/#3/#4 are safe to bracket this
 * way; #0/#1 have a genuinely blocking path that can resume via a
 * LATER, separate trap instance). r6 as the t0/delta holder: verified
 * free ACROSS THE IMPL CALL ITSELF -- dhruva_prio_lock_impl/dhruva_
 * prio_unlock_impl only ever touch r0-r3/r12 (never r4-r11), and
 * dhruva_mutex_unlock_impl explicitly saves/restores r4-r9 itself
 * (`stmdb sp!, {r4-r9,lr}` / matching `ldmia`) -- AAPCS-compliant
 * either way, so r6 survives the `bl <impl>` intact regardless of
 * which of the three is dispatched.
 *
 * BUG found+fixed here (self-caught via phase4_milestone.py's own
 * mandatory post-change regression run -- "integer overflow in u32
 * sub" panic partway through boot, before this file's own first
 * commit): that impl-level safety is NOT the same thing as whole-
 * round-trip safety. r6 is AAPCS callee-saved -- a vani-compiled
 * CALLER of dhruva_prio_lock/_unlock/dhruva_mutex_unlock is free to
 * keep a live value in r6 across the call, trusting it survives -- but
 * the trampolines below (dhruva_prio_lock/_unlock/dhruva_mutex_unlock)
 * only ever save/restore r4/r7 around the trap (the true-lr and
 * syscall-number fixes, see this file's own earlier header comment),
 * nothing about r6. Using r6 as bare scratch here, with no save of its
 * own, silently destroyed any live value a caller held there --
 * exactly the same bug class this file's own "SECOND real bug" fix
 * above already hit once (r5/r8/r9/r11 used as scratch without saving
 * first). Fixed by push/pop-ing r6 around the ENTIRE measured region
 * in each dispatch stub below (not just inside these two helpers),
 * preserving the caller's true r6 across the whole round trip
 * regardless of what this instrumentation does with it internally.
 *
 * Safe as a bare register hand-off between measure_start/measure_end
 * with no locking of its own: IRQ is auto-masked by the `swi`
 * exception entry itself and FIQ by swi_entry's own `cpsid f` above,
 * so nothing can interleave a DIFFERENT syscall's own start/end pair
 * between these two calls on this single core. lr is free to clobber
 * via these nested `bl`s -- not needed again until swi_return_to_usr's
 * own fresh table lookups, which don't depend on it (see that
 * function's own header comment). */
swi_fast_measure_start:
    ldr r6, =0x20003004        /* TIMER_CLO */
    ldr r6, [r6]
    bx lr

swi_fast_measure_end:
    push {r0, r1}
    ldr r12, =0x20003004       /* TIMER_CLO */
    ldr r12, [r12]
    sub r6, r12, r6             /* r6 = elapsed us */
    ldr r12, =swi_fast_total_us
    ldr r1, [r12]
    add r1, r1, r6
    str r1, [r12]
    ldr r12, =swi_fast_count
    ldr r1, [r12]
    add r1, r1, #1
    str r1, [r12]
    ldr r12, =swi_fast_worst_us
    ldr r1, [r12]
    cmp r6, r1
    strgt r6, [r12]
    pop {r0, r1}
    bx lr

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

    /* Gated on is_usr_mode_task, matching swi_entry's own entry-capture
     * fix above and scheduler_restore_usr_sp's own established pattern
     * -- see that fix's own comment for the full "why" (this restore
     * must NOT touch sp_usr for an SVC-mode caller sharing a task_index
     * with a genuinely USR-mode task, e.g. kernel_main.vani's own
     * boot-time execution and task_a both being index 0). r12, not r3,
     * for the lookup -- r3 still needs to hold usr_sp_table's own
     * looked-up value afterward, unclobbered. */
    ldr r12, =is_usr_mode_task
    ldr r12, [r12, r2, lsl #2]
    cmp r12, #0
    beq swi_return_skip_usr_sp_restore
    ldr r3, =usr_sp_table
    add r3, r3, r2, lsl #2     /* r3 = &usr_sp_table[current_task] --
                                * see swi_entry's own matching capture
                                * site above for the full "why" (single-
                                * instruction user-register LDM instead
                                * of a cps/mov/cps dip) */
    ldmia r3, {sp}^            /* load sp_usr directly -- no mode switch */
swi_return_skip_usr_sp_restore:

    ldr r3, =usr_resume_spsr_table
    ldr r3, [r3, r2, lsl #2]
    msr spsr_cxsf, r3

    ldr r3, =usr_resume_pc_table
    ldr lr, [r3, r2, lsl #2]
    movs pc, lr

/* Trampolines -- RE-WIRED into the live call graph as of 2026-09-19
 * (task #253 Phase 3 continued): these now carry the real, plain
 * names (task_sleep_ticks/dhruva_mutex_lock/dhruva_mutex_unlock) --
 * every existing vani-side call site (kernel_main.vani's own extern
 * "C" fn declarations, ~65 of them) resolves to these trampolines
 * unchanged, exactly as designed. The genuine privileged
 * implementations now live under context_switch.S's own _impl-
 * suffixed names (task_sleep_ticks_impl/dhruva_mutex_lock_impl/
 * dhruva_mutex_unlock_impl), reachable only via swi_do_sleep_ticks/
 * swi_do_mutex_lock/swi_do_mutex_unlock above. Syscall number in r7
 * (this file's own convention, matching swi_entry's own dispatch
 * above), arguments passed through completely unchanged in r0-r3.
 *
 * The separate SD-driver/shell-dispatch crash that surfaced downstream
 * when this trap was previously exercised at scale under live QEMU
 * testing is being actively chased now that these are wired back in --
 * see docs/RTOS_GAP_ANALYSIS.md and docs/TODO.md for the live status.
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
 * live value there.
 *
 * THIRD bug found+fixed here 2026-09-19 (same round as the cpsid f and
 * r5/r6/r8/r9/r11 fixes above -- found because even after both of
 * those, a NEW, different-looking crash appeared at the exact same
 * ctxsw=94 moment: buf_write_byte called with r0=0 from dharafs_read_
 * from_block_raw, a NULL base pointer, matching this project's own
 * previously-documented "was the base pointer really 0" crash shape --
 * see vectors.S's own round-62c comment): r7 carries the syscall
 * number below (`mov r7, #0/1/2`), but r7 is ALSO AAPCS callee-saved,
 * same as r4 -- and unlike r4, nothing here was saving/restoring the
 * caller's own original r7 across the trap. `mov r7, #0` (task_sleep_
 * ticks's own syscall number) makes this especially damaging: any
 * caller holding a live pointer in r7 across a task_sleep_ticks call
 * would have it silently replaced with a literal 0 (NULL) -- exactly
 * the observed symptom. Fixed the same way as r4: push the caller's
 * true r7 before overwriting it with the syscall number, pop it back
 * after `swi #0` returns -- push/pop with a register list restores in
 * register-number order regardless of list-write order, so `push
 * {r4,r7}` / `pop {r4,r7}` round-trips both correctly with no ordering
 * hazard against the `mov r7,#N` in between. */
.global task_sleep_ticks
task_sleep_ticks:
    push {r4, r7}
    mov r4, lr
    mov r7, #0
    swi #0
    mov lr, r4
    pop {r4, r7}
    bx lr

.global dhruva_mutex_lock
dhruva_mutex_lock:
    push {r4, r7}
    mov r4, lr
    mov r7, #1
    swi #0
    mov lr, r4
    pop {r4, r7}
    bx lr

.global dhruva_mutex_unlock
dhruva_mutex_unlock:
    push {r4, r7}
    mov r4, lr
    mov r7, #2
    swi #0
    mov lr, r4
    pop {r4, r7}
    bx lr

/* Task #253 Phase 3 continued (2026-09-19): dhruva_prio_lock/_unlock
 * added as syscalls #3/#4 -- see context_switch.S's own dhruva_prio_
 * lock_impl/_unlock_impl header comment for the full "why" (these used
 * to be callable directly, no trap, until a genuine race between two
 * concurrently-preemptible USR-mode tasks -- task_a and task_d/IDLE --
 * both racing through the unmasked read-current_task-then-write
 * sequence corrupted scheduler state; the fix needs `cpsid if`, which
 * is a privileged instruction and silently a no-op in USR mode, so it
 * has to run on the SVC side of a real trap, same as every other
 * privileged operation in this file). Same trampoline shape as the
 * three above. */
.global dhruva_prio_lock
dhruva_prio_lock:
    push {r4, r7}
    mov r4, lr
    mov r7, #3
    swi #0
    mov lr, r4
    pop {r4, r7}
    bx lr

.global dhruva_prio_unlock
dhruva_prio_unlock:
    push {r4, r7}
    mov r4, lr
    mov r7, #4
    swi #0
    mov lr, r4
    pop {r4, r7}
    bx lr
