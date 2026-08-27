/* Dhruva Phase 2 -- fixed-priority preemptive scheduler + a minimal
 * Immediate Priority Ceiling Protocol mutex (ARM32).
 *
 * Three statically-prioritized tasks now (HIGH=0, MEDIUM=1, LOW=2 --
 * lower number wins), replacing Step B's plain 2-task round-robin.
 * scheduler_pick_next is the shared "who runs next" decision, called
 * from both the timer-tick path (scheduler_switch_from_irq) and the
 * new voluntary path (task_sleep_ticks) -- the same policy either way.
 *
 * Priority numbering reservation (DHRUVA_ARCHITECTURE.md §4): idle is
 * deliberately the numerically-worst priority in this scheme (4, as
 * of Phase 3's task #5 below), not a hardcoded constant elsewhere --
 * when phase 6 networking adds a best-effort/network task band, it
 * belongs numerically *between* the lowest hard-RT priority and idle,
 * never above any hard-RT task. Phase 3's GC/compaction task is the
 * first tenant of exactly that reserved band: task index 4 (GC),
 * priority 3 -- below every hard-RT task (HIGH/MEDIUM/LOW, priorities
 * 0-2), above idle (priority 4, moved up one from Phase 2 to make
 * room). Task INDEX and priority NUMBER are independent by design
 * (eff_prio_table maps one to the other) -- GC is task index 4 here
 * only because it's the newest addition, not because index and
 * priority need to match; idle keeps its original index (3) with a
 * new priority value (4).
 *
 * Why dhruva_prio_lock/dhruva_prio_unlock don't need a locked-flag or owner field:
 * this is the actual point of Immediate Priority Ceiling Protocol, not
 * a shortcut. They just write the CALLING task's eff_prio_table entry
 * (boost to the mutex's ceiling on lock, restore to the task's true
 * priority on unlock) -- pure data, no switch of their own. Given a
 * mutex's ceiling is set to the highest priority of any task that will
 * ever lock it (0, HIGH's own priority, in this demo's single shared
 * mutex), NOTHING can be scheduled ahead of the current holder while
 * it holds the lock: scheduler_pick_next's "ties favor the incumbent"
 * rule means even HIGH itself, arriving at the same effective priority
 * the holder is now boosted to, does not preempt it. That's exactly
 * the textbook ceiling-protocol guarantee -- a task can never observe
 * a correctly-ceiling-assigned mutex already locked when it tries to
 * acquire it -- and it's what makes an explicit locked-flag/wait-queue
 * unnecessary for a single, non-nested shared resource. A general
 * multi-mutex system genuinely needs that machinery; this demo
 * doesn't, and pretending otherwise here would just be complexity
 * without a corresponding correctness need.
 *
 * Why task_sleep_ticks needs its own full context save (unlike
 * dhruva_prio_lock/unlock): unlike a priority-table write, giving up the CPU
 * means this task's own registers must survive until something resumes
 * it later -- exactly the same requirement boot/irq_entry.S has, and
 * for the same reason this function builds an identical-shaped frame
 * (spsr, pad, r0-r12, lr) so scheduler_pick_next's return value can be
 * restored by the exact same sequence regardless of whether a task was
 * suspended by the timer or by voluntarily sleeping.
 */

.section ".bss"
.align 4
sp_table:
    .word 0, 0, 0, 0, 0, 0  /* saved/current sp per task; index 3 =
                          * idle, index 4 = GC/compaction (Phase 3
                          * task #5), index 5 = shell (Phase 4) */
eff_prio_table:
    .word 0, 0, 0, 0, 0, 0  /* effective (possibly ceiling-boosted)
                          * priority; initialized to each task's true
                          * priority by start_multitasking, since .bss
                          * is merely zeroed at boot, not set to
                          * {0,1,2,3,4,3} */
sleep_until_table:
    .word 0, 0, 0, 0, 0, 0  /* tick_count value at which a task becomes
                          * ready again; 0 (the zeroed .bss default)
                          * means "never slept, always ready" since
                          * 0 <= any tick_count trivially holds -- true
                          * of idle (index 3) forever, since it never
                          * calls task_sleep_ticks */
tick_count:
    .word 0
current_task:
    .word 0

.section ".text"

/* Shared "who runs next" policy: the lowest eff_prio_table value among
 * tasks whose sleep_until_table <= tick_count (i.e. ready), ties
 * favoring whichever task is already current_task. Returns r0 = the
 * chosen task's sp and updates current_task -- does not touch the
 * stack itself (the caller has already saved everything that matters
 * before reaching here), so this is safe to freely clobber r0-r9 in.
 *
 * Task 3 is a dedicated idle task (priority 3, worse than every real
 * task, never sleeps) -- the standard RTOS answer to "what runs when
 * nothing else is ready," and load-bearing here for a subtler reason
 * than usual: this function seeds its "best so far" with the CURRENT
 * task regardless of whether it's actually ready (so a genuinely tied,
 * ready incumbent is correctly preferred without special-casing the
 * comparison operator). Found the hard way: without an always-ready
 * fallback candidate, that seed choice means "nobody else happens to
 * be ready right now" silently re-selects a task that just called
 * task_sleep_ticks to stop running -- its own sleep request completely
 * ignored, looping it forever instead of ever truly yielding. Idle
 * guarantees the scan always has at least one real, ready candidate to
 * fall back to instead. */
scheduler_pick_next:
    ldr r0, =tick_count
    ldr r1, [r0]                  /* r1 = tick_count */
    ldr r2, =current_task
    ldr r3, [r2]                  /* r3 = current task index */
    ldr r4, =eff_prio_table
    ldr r5, =sleep_until_table

    ldr r6, [r5, r3, lsl #2]      /* sleep_until[current] */
    cmp r6, r1
    ldrle r7, [r4, r3, lsl #2]    /* ready -> seed with its eff_prio */
    movgt r7, #255                 /* not ready -> sentinel; idle (below)
                                    * always beats this if current isn't
                                    * actually ready */
    mov r8, r3                     /* tentative best index = current */

    mov r9, #0
spn_loop:
    cmp r9, #6                     /* 6 tasks now: HIGH, MEDIUM, LOW, IDLE, GC, SHELL */
    bge spn_done
    cmp r9, r3
    beq spn_next                   /* current already accounted for above --
                                    * skip so it can't out-tie itself and
                                    * so a not-ready current can't be
                                    * mistaken for a fresh, ready candidate */
    ldr r6, [r5, r9, lsl #2]      /* sleep_until[i] */
    cmp r6, r1
    bgt spn_next                   /* not ready -> skip */
    ldr r6, [r4, r9, lsl #2]      /* eff_prio[i] */
    cmp r6, r7
    movlt r7, r6
    movlt r8, r9
spn_next:
    add r9, r9, #1
    b spn_loop
spn_done:
    str r8, [r2]                   /* current_task = best index */
    ldr r6, =sp_table
    ldr r0, [r6, r8, lsl #2]      /* r0 = sp_table[best] */
    bx lr

/* void *scheduler_switch_from_irq(void *current_sp)
 * Called only from boot/irq_entry.S, after it has saved the
 * interrupted task's full context. Records that context, advances
 * tick_count (every timer tick, exactly once), and tail-calls the
 * shared policy. */
.global scheduler_switch_from_irq
scheduler_switch_from_irq:
    ldr r1, =current_task
    ldr r2, [r1]
    ldr r3, =sp_table
    str r0, [r3, r2, lsl #2]      /* sp_table[current] = current_sp */

    ldr r4, =tick_count
    ldr r5, [r4]
    add r5, r5, #1
    str r5, [r4]

    b scheduler_pick_next          /* tail call: its `bx lr` returns to
                                    * OUR caller (irq_entry.S) directly */

/* void task_sleep_ticks(i64 ticks)
 * Voluntarily gives up the CPU until at least `ticks` timer ticks have
 * elapsed. Builds its own full-context frame (unlike dhruva_prio_lock/
 * unlock, which never switch anything) because this task will not run
 * again until something else resumes it later, possibly a long time
 * and many other switches after this call returns control (from this
 * function's own perspective, "returns" and "gets resumed" are the
 * same event). ticks is a plain i64, so AAPCS's 64-bit-argument
 * register pairing applies (r0:r1) -- only r0 (the low 32 bits) is
 * used, since no tick count in this design remotely approaches 2^32. */
.global task_sleep_ticks
task_sleep_ticks:
    stmdb sp!, {r0-r12, lr}        /* 14 words = 56 bytes */
    mov r2, #0x13
    mov r3, #0
    stmdb sp!, {r2, r3}             /* spsr=0x13, pad -- 8 bytes, 64 total */

    mov r4, sp                      /* r4 = this context's sp */
    ldr r5, =current_task
    ldr r6, [r5]
    ldr r7, =tick_count
    ldr r8, [r7]
    add r8, r8, r0                  /* wake_time = tick_count + ticks;
                                     * r0 is still the original arg --
                                     * stmdb only reads registers, it
                                     * never modifies the source list */
    ldr r9, =sleep_until_table
    str r8, [r9, r6, lsl #2]

    ldr r9, =sp_table
    str r4, [r9, r6, lsl #2]        /* sp_table[current] = our saved sp */

    bl scheduler_pick_next
    mov sp, r0
    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr}
    subs pc, lr, #0

/* i64 dhruva_prio_lock(i64 ceiling) -- boosts the calling task's effective
 * priority to `ceiling`. i64 dhruva_prio_unlock(i64 base_priority) --
 * restores it. Both plain data writes; see the file header for why no
 * lock-state/switch is needed here. */
.global dhruva_prio_lock
dhruva_prio_lock:
    ldr r2, =current_task
    ldr r3, [r2]
    ldr r2, =eff_prio_table
    str r0, [r2, r3, lsl #2]
    mov r0, #0              /* return value: 0 (unused by every caller
                              * today, but see test_compare_buffers'
                              * comment in sdcard_state.S for why a
                              * garbage-high-word i64 return is a real,
                              * not just theoretical, bug class here) */
    mov r1, #0
    bx lr

.global dhruva_prio_unlock
dhruva_prio_unlock:
    ldr r2, =current_task
    ldr r3, [r2]
    ldr r2, =eff_prio_table
    str r0, [r2, r3, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

/* mut ref i64 task_{a,b,c,d}_init_stack(mut ref i64 stack_base, i64 stack_bytes)
 * Builds a fake initial context, shaped identically to what every
 * restore path above expects (spsr, pad, r0-r12, lr). spsr=0x13 (SVC
 * mode, IRQ/FIQ enabled, ARM state), not zero -- zero decodes to a
 * reserved/invalid CPSR mode field, corrupting the CPU the instant a
 * task is first resumed. task_d is the idle task (see scheduler_pick_
 * next's comment for why it exists). */
.global task_a_init_stack
task_a_init_stack:
    add r0, r0, r2
    ldr r1, =task_a
    b prepare_stack_common

.global task_b_init_stack
task_b_init_stack:
    add r0, r0, r2
    ldr r1, =task_b
    b prepare_stack_common

.global task_c_init_stack
task_c_init_stack:
    add r0, r0, r2
    ldr r1, =task_c
    b prepare_stack_common

.global task_d_init_stack
task_d_init_stack:
    add r0, r0, r2
    ldr r1, =task_d
    b prepare_stack_common

.global task_e_init_stack
task_e_init_stack:
    add r0, r0, r2
    ldr r1, =task_e
    b prepare_stack_common

.global task_f_init_stack
task_f_init_stack:
    add r0, r0, r2
    ldr r1, =task_f
    b prepare_stack_common

prepare_stack_common:
    sub r0, r0, #64
    mov r2, #0x13
    str r2, [r0, #0]       /* spsr */
    mov r2, #0
    str r2, [r0, #4]       /* pad */
    str r2, [r0, #8]       /* r0 */
    str r2, [r0, #12]      /* r1 */
    str r2, [r0, #16]      /* r2 */
    str r2, [r0, #20]      /* r3 */
    str r2, [r0, #24]      /* r4 */
    str r2, [r0, #28]      /* r5 */
    str r2, [r0, #32]      /* r6 */
    str r2, [r0, #36]      /* r7 */
    str r2, [r0, #40]      /* r8 */
    str r2, [r0, #44]      /* r9 */
    str r2, [r0, #48]      /* r10 */
    str r2, [r0, #52]      /* r11 */
    str r2, [r0, #56]      /* r12 */
    str r1, [r0, #60]      /* lr = entry point */
    bx lr

/* i64 start_multitasking(mut ref i64 sp_a, mut ref i64 sp_b,
 *                          mut ref i64 sp_c, mut ref i64 sp_d,
 *                          mut ref i64 sp_e, mut ref i64 sp_f)
 * Seeds sp_table and eff_prio_table (base priorities -- .bss is only
 * zeroed by boot.S, not pre-set to {0,1,2,3,4,3}) and enters task_a
 * (HIGH) for the first time. Six ref args: the first four -> r0, r1,
 * r2, r3, one register each (no AAPCS pairing concern -- that's only
 * for plain i64 scalar args), filling every core argument register
 * with none left over. The fifth and sixth (sp_e, sp_f) have nowhere
 * left to go but the stack, at [sp,#0] and [sp,#4] respectively --
 * confirmed directly from throwaway probe functions' callsite
 * disassembly (`strd r8, [sp]`, storing r8 and r9 as a pair) before
 * writing this, same discipline as every other AAPCS assumption this
 * project has been burned by trusting instead of checking. r3 (sp_d)
 * must be saved off before it's reused as scratch for table addresses
 * below, and sp_e/sp_f must be read from the stack before this
 * function's own first push changes what those offsets mean. Never
 * returns in practice. */
.global start_multitasking
start_multitasking:
    ldr r4, [sp, #0]           /* sp_e, passed on the stack -- read
                                 * before anything below touches sp */
    ldr r8, [sp, #4]           /* sp_f, likewise */
    mov r5, r3                 /* save sp_d before r3 becomes scratch */

    ldr r6, =sp_table
    str r0, [r6, #0]
    str r1, [r6, #4]
    str r2, [r6, #8]
    str r5, [r6, #12]
    str r4, [r6, #16]          /* task 4 (GC) */
    str r8, [r6, #20]          /* task 5 (SHELL) */

    ldr r6, =eff_prio_table
    mov r7, #0
    str r7, [r6, #0]         /* task 0 (HIGH) priority 0 */
    mov r7, #1
    str r7, [r6, #4]         /* task 1 (MEDIUM) priority 1 */
    mov r7, #2
    str r7, [r6, #8]         /* task 2 (LOW) priority 2 */
    mov r7, #3
    str r7, [r6, #16]        /* task 4 (GC) priority 3 -- the reserved
                               * best-effort band, below every hard-RT
                               * task, above idle */
    str r7, [r6, #20]        /* task 5 (SHELL) priority 3 too -- same
                               * best-effort band as GC; ties between
                               * them favor whichever is incumbent,
                               * fine since both are normally sleeping
                               * and rarely contend at the same instant */
    mov r7, #4
    str r7, [r6, #12]        /* task 3 (IDLE) priority 4 -- worst,
                               * as always */

    ldr r6, =current_task
    mov r7, #0
    str r7, [r6]

    mov sp, r0
    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr}
    subs pc, lr, #0
