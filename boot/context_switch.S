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

/* MAX_TASKS = 16 (round 54's general task-creation API): indices
 * 0-5 are the original fixed set (HIGH/MEDIUM/LOW/IDLE/GC/SHELL,
 * unchanged); 6-15 are free slots task_create can hand out at
 * runtime. eff_prio_table's own "255" sentinel marks a slot as
 * genuinely unused (never created, or -- there is no task-deletion
 * API yet -- see docs/TODO.md) rather than needing a separate
 * task_count variable: 255 is outside every real priority value this
 * scheduler has ever used (0-4 today), so an unused slot can never
 * win scheduler_pick_next's own "lowest eff_prio wins" comparison
 * against any real task, including idle (priority 4) -- verified by
 * tracing the comparison logic, not assumed. scheduler_ready_count
 * DOES need an explicit check against this sentinel (see its own
 * comment below) since it doesn't otherwise consult eff_prio_table at
 * all. start_multitasking seeds indices 6-15 to 255 explicitly --
 * .bss's own zero-init would otherwise leave them at 0, which looks
 * like a real, ready, HIGHEST-priority task and would crash the
 * instant the scheduler ever tried to switch to that slot's
 * uninitialized stack pointer before any real task_create() call. */
.section ".bss"
.align 4
sp_table:
    .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  /* saved/
                          * current sp per task; index 3 = idle, index
                          * 4 = GC/compaction (Phase 3 task #5), index
                          * 5 = shell (Phase 4), 6-15 = task_create's
                          * own free slots */
eff_prio_table:
    .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  /* effective
                          * (possibly ceiling-boosted) priority;
                          * initialized to each fixed task's true
                          * priority by start_multitasking (.bss is
                          * merely zeroed at boot, not set to
                          * {0,1,2,3,4,3,...}), and to the 255 "unused"
                          * sentinel for indices 6-15 until task_create
                          * populates one */
sleep_until_table:
    .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  /* tick_count
                          * value at which a task becomes ready again;
                          * 0 (the zeroed .bss default) means "never
                          * slept, always ready" since 0 <= any
                          * tick_count trivially holds -- true of idle
                          * (index 3) forever, since it never calls
                          * task_sleep_ticks, and harmless for an
                          * unused slot 6-15 too (eff_prio's own 255
                          * sentinel is what actually keeps
                          * scheduler_pick_next from ever picking it,
                          * regardless of this table's own value there) */
tick_count:
    .word 0
current_task:
    .word 0
context_switch_count:
    .word 0             /* Round 53: total number of times scheduler_
                         * pick_next actually changed current_task to a
                         * DIFFERENT task -- not just how many times it
                         * ran (which happens every tick regardless of
                         * whether anything changed). A real,
                         * workload-independent metric: this counts
                         * genuine scheduling activity no matter what
                         * the running tasks actually do, unlike a
                         * deadline/budget model (which needs a real
                         * timing-constrained task to mean anything --
                         * see docs/TODO.md's own note on why that's
                         * deferred). */
prio_lock_count:
    .word 0             /* Round 53: total number of dhruva_prio_lock
                         * calls -- how many times any task entered a
                         * ceiling-protected critical section. */
irq_count:
    .word 0             /* Round 53: total number of IRQs serviced
                         * (both the 500ms timer tick and UART RX) --
                         * incremented from kernel_main.vani's own
                         * irq_dispatch, which runs on every one. */
rr_last_picked:
    .word 0             /* Round 75: round-robin cursor for fairness
                         * among equal-priority ready tasks -- see
                         * scheduler_pick_next's own updated header
                         * comment. The index most recently chosen by
                         * the NEW (non-ceiling-protected) tie-breaking
                         * path; the next tie starts its scan just past
                         * this index, so repeated ties rotate through
                         * every ready contender instead of always
                         * landing on the same one. .bss's zero-init
                         * start is harmless -- worst case, the very
                         * first tie ever broken starts its scan at
                         * index 1 instead of some other arbitrary
                         * index, no different in kind from any other
                         * starting point. */

/* Round 55: a real, second synchronization primitive (dhruva_mutex_
 * lock/unlock, below) alongside the existing priority-CEILING protocol
 * (dhruva_prio_lock/unlock, above) -- a genuine blocking mutex with
 * PRIORITY INHERITANCE, where a lower-priority holder really can delay
 * a higher-priority waiter and that delay is recovered from dynamically
 * (unlike ceiling protocol, which prevents the delay from ever
 * happening by construction). See dhruva_mutex_lock's own comment. */
base_prio_table:
    .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0  /* each task's
                          * TRUE, uninherited priority. Needed because
                          * inheritance can boost a task's eff_prio_
                          * table entry on behalf of a waiter the
                          * boosted task never itself knows about -- so
                          * there must be a separate place to restore
                          * from on unlock, unlike dhruva_prio_lock/
                          * unlock's ceiling protocol, where the caller
                          * always already knows its own base priority
                          * statically and passes it back explicitly.
                          * Populated by start_multitasking for the 6
                          * fixed tasks and by task_create for dynamic
                          * ones, exactly mirroring eff_prio_table's own
                          * seeding. */
.equ MAX_MUTEXES, 4
mutex_owner_table:
    .word 0, 0, 0, 0    /* owning task index per mutex, or 255
                         * ("unlocked") -- task_table_init seeds this to
                         * 255 for all MAX_MUTEXES slots before anything
                         * can call dhruva_mutex_lock, same sentinel
                         * convention as eff_prio_table's free-slot
                         * marker. */
mutex_waiters_table:
    .word 0, 0, 0, 0    /* one bit per task index (0-15) currently
                         * blocked in dhruva_mutex_lock on this mutex.
                         * .bss's own zero-init is already the correct
                         * "nobody waiting" default -- no seeding
                         * needed, unlike mutex_owner_table's 255
                         * sentinel. */

/* Round 59: priority-inversion instrumentation -- the "remaining, not
 * done" note on the blocking mutex's own docs/TODO.md entry. A real
 * blocking primitive (round 55) is what FINALLY makes any of this
 * observable at all (the priority-CEILING protocol prevents inversion
 * by construction, producing no scheduling-visible signal to measure
 * -- see that TODO.md entry's own history). */
mutex_contention_count:
    .word 0             /* total number of times dhruva_mutex_lock
                         * actually had to block a caller (mutex already
                         * held) -- NOT how many times it was called;
                         * an uncontended lock/unlock pair increments
                         * nothing here, matching context_switch_count's
                         * own "count real events, not call volume"
                         * convention (round 53). */
mutex_wait_worst_ticks:
    .word 0             /* the longest observed gap, in ticks, between
                         * a task blocking in dhruva_mutex_lock and
                         * dhruva_mutex_unlock actually handing it
                         * ownership -- a real worst-case wait, not an
                         * estimate. .bss's zero-init is the correct
                         * "no contention observed yet" starting value
                         * (a real wait is always >= 1 tick by the time
                         * it's even measurable, since blocking and
                         * resuming can't happen within the same tick
                         * this driver can distinguish). */
mutex_block_start_tick_table:
    .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                        /* tick_count at the moment task[i] most
                         * recently blocked in dhruva_mutex_lock --
                         * parallel to sleep_until_table (MAX_TASKS=16
                         * entries), read back by dhruva_mutex_unlock
                         * when it hands ownership to task[i] to compute
                         * how long it actually waited. Not meaningful
                         * for a task that has never blocked (reads 0,
                         * i.e. "tick 0" -- harmless, since this table is
                         * only ever READ for a task dhruva_mutex_unlock
                         * is actively waking from mutex_waiters_table,
                         * which can only be set by dhruva_mutex_lock
                         * having already written this entry first). */

.section ".text"

/* Shared "who runs next" policy: the lowest eff_prio_table value among
 * tasks whose sleep_until_table <= tick_count (i.e. ready). Returns
 * r0 = the chosen task's sp and updates current_task -- does not touch
 * the stack itself (the caller has already saved everything that
 * matters before reaching here), so this is safe to freely clobber
 * r0-r9 (and now r12) in.
 *
 * Task 3 is a dedicated idle task (priority 3, worse than every real
 * task, never sleeps) -- the standard RTOS answer to "what runs when
 * nothing else is ready," and load-bearing for a subtler reason too:
 * it guarantees the scan below always has at least one real, ready
 * candidate to fall back to, so "nobody else happens to be ready right
 * now" can never silently re-select a task that just called task_
 * sleep_ticks to stop running (its own sleep request would otherwise
 * be completely ignored, looping it forever instead of ever truly
 * yielding -- found the hard way, an early Phase 2 bug).
 *
 * ROUND 75 UPDATE: this used to unconditionally favor whichever task
 * was already current_task on any tie (docs/RTOS_GAP_ANALYSIS.md's own
 * "No fairness among equal-priority ready tasks" gap -- two always-
 * ready tasks at the same priority, e.g. indices 2 and 5, meant index
 * 2 won forever and 5 could starve indefinitely, confirmed by reading
 * the old `cmp r6,r7 / movlt r7,r6 / movlt r8,r9` comparison directly).
 * Now rotates fairly among genuine ties via rr_last_picked -- BUT ONLY
 * when doing so is actually safe. It is NOT safe unconditionally: this
 * project's priority-CEILING protocol (dhruva_prio_lock/unlock, above)
 * depends specifically on ties favoring the incumbent whenever that
 * incumbent is the one currently holding a ceiling-boosted lock --
 * that is the entire mechanism by which a correctly-ceiling-assigned
 * mutex holder can never be preempted by a task arriving at the same
 * (boosted) effective priority (see this file's own top-of-file
 * comment on dhruva_prio_lock/unlock). Round-robin-ing that exact tie
 * would silently reintroduce the race the protocol exists to prevent.
 *
 * So: if current_task is ready AND currently boosted (eff_prio_table
 * < base_prio_table for it -- i.e. it holds a ceiling-protected lock
 * right now), this function falls back to the OLD "ties favor the
 * incumbent" algorithm, completely unchanged, for that one decision.
 * Otherwise (current not ready, or ready but at its own true
 * priority), it uses the NEW round-robin-aware algorithm. Known,
 * accepted limitation: this only special-cases a BOOSTED CURRENT task,
 * not a hypothetical boosted NON-current task -- true of every mutex
 * this project exercises today (a task is only ever boosted while it
 * is the one actually running), but worth re-checking if a future
 * round (docs/TODO.md's DharaFS-concurrency item) ever has two
 * independent ceiling-protected critical sections active concurrently
 * on different tasks.
 *
 * NOT self-tested directly (round 75): a white-box test calling this
 * function against controlled table state (via a `.global` escape
 * hatch + TEST-ONLY setters, all since removed) was attempted and
 * abandoned after finding a real, unresolved bug it triggered live --
 * this function freely clobbers r4-r7 as scratch without saving them,
 * safe for its actual callers below (both hand-written assembly in
 * this same file, which already account for it) but a genuine AAPCS
 * violation the instant anything following the standard C ABI (vani's
 * own generated code, which treats r4-r7 as callee-saved) calls it
 * directly -- corrupting live local state elsewhere with no fault at
 * the point of corruption. A wrapper saving/restoring r4-r11 around
 * the call fixed THAT bug specifically (confirmed via disassembly:
 * push/pop pairing was correctly balanced), but a second, deeper crash
 * remained (a real Data Abort inside the wrapper's own return path,
 * SP found jumping ~200KB to a wild, unmapped address for reasons not
 * fully root-caused despite extensive live tracing) that didn't
 * reproduce even with the wrapper fix in place. Given the actual
 * algorithm change above was already independently verified via full
 * live regression (phase4_milestone.py's own MUTEX-LOW/HIGH ceiling-
 * protocol demo trace, byte-for-byte unchanged from before this
 * round, plus correct task_create() slot ordering), shipping a
 * self-test that could crash the system was judged worse than having
 * no automated self-test for this specific property at all. If a
 * future round wants to add one, calling scheduler_pick_next (or any
 * wrapper around it) from vani-compiled code is the first suspect if
 * it reproduces this same failure mode again -- do not assume a
 * simple r4-r11 save/restore wrapper alone is sufficient without
 * re-verifying live under QEMU first. */
scheduler_pick_next:
    /* Round 65 hardening: this function freely uses r8-r11 as scratch
     * below (tentative-best index, loop counter, context_switch_count
     * bookkeeping) without ever saving/restoring them, on the theory
     * that it's always safe -- whichever task is "live" in these
     * registers at the call site has already had its full context
     * (r0-r12) saved elsewhere (irq_entry.S's relocate step, or this
     * same function's own sibling task_sleep_ticks/dhruva_mutex_unlock
     * frame-building) before this ever runs, and gets it restored
     * afterward regardless of what this function leaves in the live
     * registers. That reasoning is still believed correct, but a live
     * investigation (project memory: Dhruva round 65, the task_f
     * runtime-trap bug) directly observed r8 -- which sha256_compress
     * holds its own `w` message-schedule pointer in for its ENTIRE
     * execution, per an earlier round's own finding -- change value
     * across exactly this function's own entry/exit while a real IRQ
     * fired mid-computation, immediately preceding (within 1-2
     * instructions) a genuine wild-pointer Data Abort in the resumed
     * task. Never proven to be THIS specific clobber causing that
     * abort (the resumed task's own r8 read back correctly restored in
     * the same trace), but this is the one concrete, reproducible
     * anomaly found after extensive live tracing, sits exactly on the
     * interrupt-affected call path, and costs nothing to harden
     * defensively: explicitly preserve the caller's r8-r11 the same
     * way this project's own scheduler_switch_from_irq (which tail-
     * calls straight into this function) and irq_entry.S's own save/
     * restore already treat every other register. */
    push {r8, r9, r10, r11}
    ldr r0, =tick_count
    ldr r1, [r0]                  /* r1 = tick_count */
    ldr r2, =current_task
    ldr r3, [r2]                  /* r3 = current task index */
    ldr r4, =eff_prio_table
    ldr r5, =sleep_until_table

    /* Round 75 gate: is current_task ready right now, AND currently
     * boosted (holding a ceiling-protected lock)? If so, this decision
     * MUST use the old "ties favor the incumbent" algorithm -- see
     * this function's own header comment for why round-robin here
     * would be a real correctness regression, not just a style choice. */
    ldr r6, [r5, r3, lsl #2]      /* sleep_until[current] */
    cmp r6, r1
    bgt spn_new_algorithm          /* current not ready -> no protection
                                    * needed, use the fair algorithm */
    ldr r6, [r4, r3, lsl #2]      /* eff_prio[current] */
    ldr r12, =base_prio_table
    ldr r7, [r12, r3, lsl #2]     /* base_prio[current] */
    cmp r6, r7
    bge spn_new_algorithm          /* eff_prio >= base_prio -> not
                                    * boosted, use the fair algorithm */

spn_old_algorithm:
    /* Unchanged from before round 75: ties favor the incumbent
     * unconditionally. Only reached when current_task is ready AND
     * boosted, so r7 is always current's own (boosted) eff_prio here
     * -- re-seed explicitly rather than relying on the gate above
     * having left the right value in r7 (it did, but re-reading is
     * cheap and keeps this block self-contained/independently
     * readable). */
    ldr r7, [r4, r3, lsl #2]       /* seed = eff_prio[current] */
    mov r8, r3                     /* tentative best index = current */

    mov r9, #0
spn_loop:
    cmp r9, #16                    /* MAX_TASKS (round 54) -- indices
                                    * 6-15 are task_create's own free
                                    * slots, eff_prio=255 until
                                    * populated, which this loop's own
                                    * existing `cmp r6,r7 / movlt`
                                    * comparison already handles
                                    * correctly with no other change
                                    * needed (255 can never beat idle's
                                    * real priority 4, verified by
                                    * tracing this exact comparison) */
    bge spn_finish
    cmp r9, r3
    beq spn_next                   /* current already accounted for above --
                                    * skip so it can't out-tie itself */
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

spn_new_algorithm:
    /* Round 75: fair (round-robin) tie-breaking, safe here because
     * current_task is either not ready or not boosted (gated above).
     * Pass 1 -- find the lowest eff_prio among ALL ready tasks
     * (including current, which competes on equal footing with
     * everyone else in this path). Idle (index 3, priority 4, never
     * sleeps) guarantees r7 always ends up <= 4, never the empty-scan
     * sentinel. */
    mov r7, #255                    /* min eff_prio found so far */
    mov r9, #0
spn_p1_loop:
    cmp r9, #16
    bge spn_p1_done
    ldr r6, [r5, r9, lsl #2]       /* sleep_until[i] */
    cmp r6, r1
    bgt spn_p1_next                 /* not ready -> skip */
    ldr r6, [r4, r9, lsl #2]       /* eff_prio[i] */
    cmp r6, r7
    movlt r7, r6
spn_p1_next:
    add r9, r9, #1
    b spn_p1_loop
spn_p1_done:
    /* Pass 2 -- among ready tasks tied at r7 (the min just found),
     * pick whichever comes first when scanning circularly starting
     * just AFTER rr_last_picked, so repeated ties rotate through every
     * tied contender in turn instead of always landing on the same
     * index. r9 here is an OFFSET (1..16) from rr_last_picked, not a
     * raw task index -- `and r6,r6,#15` folds it back into 0-15 (valid
     * since MAX_TASKS=16 is a power of 2). */
    ldr r10, =rr_last_picked
    ldr r11, [r10]                  /* r11 = last picked index */
    mov r9, #1
spn_p2_loop:
    add r6, r11, r9
    and r6, r6, #15                 /* r6 = candidate index */
    ldr r0, [r5, r6, lsl #2]       /* sleep_until[candidate] */
    cmp r0, r1
    bgt spn_p2_next                 /* not ready -> skip */
    ldr r0, [r4, r6, lsl #2]       /* eff_prio[candidate] */
    cmp r0, r7
    bne spn_p2_next                 /* not at the min priority -> skip */
    mov r8, r6                      /* found this tick's pick */
    b spn_p2_found
spn_p2_next:
    add r9, r9, #1
    cmp r9, #16
    ble spn_p2_loop
    mov r8, #3                      /* unreachable in practice -- idle
                                    * (index 3) is always ready and
                                    * always <= min_prio, so pass 2
                                    * always finds a match within 16
                                    * steps; fall back to idle
                                    * explicitly rather than leaving r8
                                    * undefined if this is ever reached
                                    * anyway. */
spn_p2_found:
    str r8, [r10]                   /* rr_last_picked = this pick, so
                                    * the NEXT tie starts past it */

spn_finish:
    cmp r8, r3                     /* did the picked task actually
                                    * change from current? (r10/r11 are
                                    * free scratch here -- unused by
                                    * the rest of this function) */
    beq spn_no_switch
    ldr r10, =context_switch_count
    ldr r11, [r10]
    add r11, r11, #1
    str r11, [r10]
spn_no_switch:
    str r8, [r2]                   /* current_task = best index */
    ldr r6, =sp_table
    ldr r0, [r6, r8, lsl #2]      /* r0 = sp_table[best] -- must read
                                    * this before the pop below touches
                                    * r8, but r0 itself is untouched by
                                    * that pop either way */
    pop {r8, r9, r10, r11}         /* restore the caller's own values,
                                    * see this function's own entry
                                    * comment */
    bx lr

/* void *scheduler_switch_from_irq(void *current_sp, i64 was_timer_tick)
 * Called only from boot/irq_entry.S, after it has saved the
 * interrupted task's full context. Records that context, advances
 * tick_count (once, but ONLY when was_timer_tick is nonzero), and
 * tail-calls the shared policy.
 *
 * BUG (round 4 audit, 2026-08-27): this function used to advance
 * tick_count unconditionally, on every call -- i.e. on every IRQ
 * entry, not just a real timer tick -- directly contradicting this
 * comment's own claim of "every timer tick, exactly once". A UART RX
 * interrupt (fires whenever a character is typed at the interactive
 * shell, entirely unrelated to the 500ms timer) advanced tick_count
 * exactly as much as a genuine tick. Since tick_count is this whole
 * scheduler's only notion of elapsed time -- every task_sleep_ticks
 * call and sleep_until_table comparison is defined in terms of it --
 * typing at the shell silently sped up every other task's sleep
 * system-wide, with no relationship to real elapsed wall-clock time.
 * Fixed by having irq_entry.S pass through irq_dispatch's own new
 * return value (1 iff this IRQ was actually the timer) as a second
 * argument here, and only incrementing when it's nonzero. */
.global scheduler_switch_from_irq
scheduler_switch_from_irq:
    mov r9, r1                     /* stash was_timer_tick -- r1 is about
                                    * to be reused as scratch below */
    ldr r1, =current_task
    ldr r2, [r1]
    ldr r3, =sp_table
    str r0, [r3, r2, lsl #2]      /* sp_table[current] = current_sp */

    cmp r9, #0
    beq scheduler_switch_from_irq_skip_tick
    ldr r4, =tick_count
    ldr r5, [r4]
    add r5, r5, #1
    str r5, [r4]
scheduler_switch_from_irq_skip_tick:
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
    /* Round 65 hardening: unlike dhruva_mutex_lock's own blocked path
     * (see its header comment -- explicit `cpsid i` before touching
     * any shared scheduler state), this function never masked
     * interrupts across its own multi-instruction critical section
     * below (building this task's own switch-away frame, then writing
     * sleep_until_table/sp_table for `current_task`). A real timer
     * tick landing anywhere in that window drives irq_entry.S's own
     * concurrent save/scheduler-switch path on the SAME stack, racing
     * to write the SAME sp_table[current_task] entry this function is
     * still in the middle of populating. At the time this was written,
     * not proven to be the sole cause of the (then-)still-open task_f
     * runtime-trap bug (project memory: Dhruva round 65) -- but it was
     * a genuine, real race against concurrently-modified shared
     * scheduler state with no mutual exclusion, exactly the class of
     * bug this project's own dhruva_mutex_lock already guards against
     * in its own analogous path -- masking here is free (this function
     * always ends by switching away, never by a normal `bx lr` return,
     * so there's no "restore the caller's original mask" step needed:
     * the resumed task's own interrupt state is governed entirely by
     * the spsr this function stages into its own saved frame below,
     * not by the live cpsr at any point in this function).
     *
     * Round 68: the actual mechanism behind the INTERRUPT-DRIVEN
     * portion of that bug class is now understood and fixed -- see
     * irq_entry.S's own header comment (the saved frame's "lr" slot
     * used to conflate the interrupted task's true r14 with the resume
     * PC; any hand-written bare `bx lr` leaf -- ~300 of them project-
     * wide, every `boot/*_state.S` accessor -- interrupted mid-body
     * would resume with r14==pc and self-loop until it dereferenced
     * something unmapped). This masking stays in place regardless --
     * still a real, independent race worth closing on its own -- but
     * is very likely no longer load-bearing for the specific crash
     * class this comment originally described. Round 62f's own
     * separate finding that the SHA-256/PBKDF2 corruption could also
     * occur with ZERO interrupts (single-threaded boot, before enable_
     * irqs() ever runs) is NOT explained by the round-68 fix -- that
     * narrower mystery, if it's still reproducible, remains genuinely
     * open. */
    cpsid i
    /* Round 68: explicit 17-word (68-byte) frame -- spsr, pad, r0-r12,
     * true_lr, resume_pc -- replacing the old 16-word stmdb-built one.
     * See irq_entry.S's own header comment for the full "why" (the old
     * single "lr" slot conflated true_lr and resume_pc, harmless for a
     * VOLUNTARY switch like this one -- where they're legitimately the
     * SAME value, "whoever called task_sleep_ticks" -- but fatal for
     * irq_entry.S's involuntary path). Kept explicit `str` rather than
     * `stmdb` so the true_lr/resume_pc duplication is easy to see is
     * deliberate, not an oversight. */
    sub sp, sp, #68
    str r0, [sp, #8]
    str r1, [sp, #12]
    str r2, [sp, #16]
    str r3, [sp, #20]
    str r4, [sp, #24]
    str r5, [sp, #28]
    str r6, [sp, #32]
    str r7, [sp, #36]
    str r8, [sp, #40]
    str r9, [sp, #44]
    str r10, [sp, #48]
    str r11, [sp, #52]
    str r12, [sp, #56]
    str lr, [sp, #60]               /* true_lr (== resume point here) */
    str lr, [sp, #64]               /* resume_pc, same value duplicated */
    mov r2, #0x13
    str r2, [sp, #0]                 /* spsr */
    mov r3, #0
    str r3, [sp, #4]                 /* pad */

    mov r4, sp                      /* r4 = this context's sp */
    ldr r5, =current_task
    ldr r6, [r5]
    ldr r7, =tick_count
    ldr r8, [r7]
    add r8, r8, r0                  /* wake_time = tick_count + ticks;
                                     * r0 is still the original arg --
                                     * untouched by the explicit stores
                                     * above, same as stmdb's own
                                     * read-only-source-list behavior */
    ldr r9, =sleep_until_table
    str r8, [r9, r6, lsl #2]

    ldr r9, =sp_table
    str r4, [r9, r6, lsl #2]        /* sp_table[current] = our saved sp */

    bl scheduler_pick_next
    mov sp, r0
    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr, pc}^     /* see irq_entry.S's own restore
                                     * comment for why {lr,pc}^ replaces
                                     * the old {lr} + subs pc,lr,#0 */

/* i64 dhruva_prio_lock(i64 ceiling) -- boosts the calling task's effective
 * priority to `ceiling`. i64 dhruva_prio_unlock(i64 base_priority) --
 * restores it. Both plain data writes; see the file header for why no
 * lock-state/switch is needed here. */
.global dhruva_prio_lock
dhruva_prio_lock:
    // BUG (found live, round 53, via a genuinely corrupted UART byte
    // stream under QEMU -- caught by power_yank.py itself failing to
    // even decode the output, not a subtle test assertion): this used
    // r4/r5 as scratch for the new counter increment. dhruva_prio_lock
    // is called directly from vani-COMPILED C code (not just other
    // hand-written asm in this file), and r4-r11 are CALLEE-SAVED
    // under AAPCS -- the compiler is free to keep a live variable in
    // r4 or r5 across this call, and clobbering them without saving/
    // restoring silently corrupts whatever the caller had there. r1/r2
    // below are safe (caller-saved scratch registers, and r2 is
    // already reassigned by the pre-existing code right after, same
    // pattern this function already used for r2/r3 before this fix).
    ldr r1, =prio_lock_count
    ldr r2, [r1]
    add r2, r2, #1
    str r2, [r1]
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

/* u32 current_eff_prio() -- reads eff_prio_table[current_task]. Lets a
 * task observe its OWN effective priority live (e.g. to prove a
 * dhruva_mutex_lock inheritance boost actually happened), without
 * needing to know its own task index. Only touches r0/r1 (caller-
 * saved) -- no push/pop needed. */
.global current_eff_prio
current_eff_prio:
    ldr r0, =current_task
    ldr r0, [r0]
    ldr r1, =eff_prio_table
    ldr r0, [r1, r0, lsl #2]
    bx lr

/* u32 dhruva_mutex_lock(u32 mutex_id)
 * Round 55: a real, SECOND synchronization primitive alongside the
 * priority-CEILING protocol above (dhruva_prio_lock/unlock). Ceiling
 * protocol prevents inversion by construction (no blocking, no wait
 * queue -- see this file's header comment). This is the opposite shape
 * on purpose: a genuine wait queue where a lower-priority holder really
 * CAN delay a higher-priority waiter, with PRIORITY INHERITANCE
 * (dynamic, not a static ceiling) recovering from that delay -- the
 * waiter's own priority is temporarily lent to the holder for exactly
 * as long as it holds the mutex, restored by dhruva_mutex_unlock.
 * Ceiling protocol remains the right tool whenever every critical
 * section's ceiling is known statically in advance; this is for the
 * case where it isn't.
 *
 * Direct ownership handoff, not "wake and re-race": dhruva_mutex_unlock
 * (below) picks exactly one waiter and publishes ownership to it BEFORE
 * marking it ready, under the same IRQ-masked section as its own scan
 * -- so a task resuming from the blocked path below never re-checks
 * anything, it already owns the mutex the moment it runs again.
 *
 * Out of scope (both genuinely unneeded for this round's own demo, not
 * oversights): recursion (locking a mutex you already hold deadlocks
 * against yourself) and nested-mutex inheritance stacking (unlock
 * restores the FULL base priority unconditionally, not "the next-
 * highest ceiling still held").
 *
 * Register discipline -- this function has TWO differently-shaped
 * exits: a normal `bx lr` return (mutex was free) and a full context
 * switch away, resuming the caller much later via a saved frame (mutex
 * contended) -- same two-shaped-exit pattern as task_sleep_ticks. The
 * fast path only ever touches r0-r3 (caller-saved -- round 53's AAPCS
 * lesson about r4-r11 doesn't apply to a path that never uses them).
 * The blocked path saves the FULL r0-r12+lr context (same frame shape
 * as task_sleep_ticks) as literally its first action, before touching
 * r4-r11 as scratch -- whatever the ORIGINAL caller had in them is
 * already safely captured in the frame, and gets restored verbatim
 * whenever this task is eventually resumed, so no separate push/pop is
 * needed for that path either. The one subtlety a plain copy of
 * task_sleep_ticks wouldn't have: dhruva_mutex_lock has a real return
 * VALUE (0 = success), unlike void task_sleep_ticks, so the frame's
 * saved r0 slot is patched to 0 right after the save -- otherwise a
 * resumed caller would see r0 = the original mutex_id argument instead
 * of the return code. */
.global dhruva_mutex_lock
dhruva_mutex_lock:
    mrs r1, cpsr
    cpsid i

    ldr r2, =mutex_owner_table
    ldr r3, [r2, r0, lsl #2]
    cmp r3, #255
    bne dml_contended

    ldr r3, =current_task
    ldr r3, [r3]
    str r3, [r2, r0, lsl #2]        /* owner = current_task */
    msr cpsr_c, r1
    mov r0, #0
    bx lr

dml_contended:
    /* r0 = mutex_id, r3 = owner task index (both still live from
     * above). Full context save FIRST -- see this function's own
     * header comment. Round 68: explicit 17-word (68-byte) frame --
     * see task_sleep_ticks's own comment for the full "why" (true_lr
     * vs resume_pc split, harmless duplication for a voluntary switch
     * like this one). */
    sub sp, sp, #68
    str r0, [sp, #8]
    str r1, [sp, #12]
    str r2, [sp, #16]
    str r3, [sp, #20]
    str r4, [sp, #24]
    str r5, [sp, #28]
    str r6, [sp, #32]
    str r7, [sp, #36]
    str r8, [sp, #40]
    str r9, [sp, #44]
    str r10, [sp, #48]
    str r11, [sp, #52]
    str r12, [sp, #56]
    str lr, [sp, #60]                /* true_lr (== resume point here) */
    str lr, [sp, #64]                /* resume_pc, same value duplicated */
    mov r4, #0x13
    str r4, [sp, #0]                  /* spsr=0x13 (SVC, IRQs enabled on
                                       * restore) */
    mov r5, #0
    str r5, [sp, #4]                  /* pad */
    mov r4, sp                       /* r4 = frame base */
    mov r5, #0
    str r5, [r4, #8]                 /* patch saved r0 -> 0 (this call's
                                       * eventual return value once
                                       * resumed, not the mutex_id arg
                                       * still live in the r0 register
                                       * below) */

    ldr r5, =current_task
    ldr r5, [r5]                     /* r5 = current_task index */
    ldr r6, =sp_table
    str r4, [r6, r5, lsl #2]         /* sp_table[current] = our frame */

    /* Priority inheritance: only ever boosts, never lowers (a second,
     * lower-priority waiter arriving after an earlier boost must not
     * undo it). */
    ldr r7, =eff_prio_table
    ldr r8, [r7, r5, lsl #2]         /* current's own eff_prio */
    ldr r9, [r7, r3, lsl #2]         /* owner's (r3) current eff_prio */
    cmp r8, r9
    strlt r8, [r7, r3, lsl #2]

    /* Register as a waiter on mutex r0. */
    ldr r7, =mutex_waiters_table
    mov r9, #1
    lsl r9, r9, r5
    ldr r8, [r7, r0, lsl #2]
    orr r8, r8, r9
    str r8, [r7, r0, lsl #2]

    /* Round 59: priority-inversion instrumentation -- count this
     * genuine block (not every lock call, only ones that actually had
     * to wait), and record when it started so dhruva_mutex_unlock can
     * compute how long it actually waited once it hands this task
     * ownership. r0 (mutex_id) and r3 (owner index) are no longer
     * needed past this point, so r1/r2 are free scratch here without
     * disturbing anything the rest of this function still reads. */
    ldr r1, =mutex_contention_count
    ldr r2, [r1]
    add r2, r2, #1
    str r2, [r1]
    ldr r1, =tick_count
    ldr r2, [r1]
    ldr r1, =mutex_block_start_tick_table
    str r2, [r1, r5, lsl #2]

    /* Block: never ready via the ordinary tick comparison until
     * dhruva_mutex_unlock explicitly hands this task ownership. */
    ldr r7, =sleep_until_table
    ldr r8, =0x7FFFFFFF
    str r8, [r7, r5, lsl #2]

    bl scheduler_pick_next            /* IRQs stay masked straight
                                        * through the switch -- the
                                        * resumed frame's own spsr=0x13
                                        * re-enables them, same as
                                        * scheduler_switch_from_irq's
                                        * own tail-call, which never
                                        * explicitly re-enables either */
    mov sp, r0
    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr, pc}^     /* see irq_entry.S's own restore
                                     * comment for why {lr,pc}^ replaces
                                     * the old {lr} + subs pc,lr,#0 */

/* u32 dhruva_mutex_unlock(u32 mutex_id)
 * Always returns normally (never suspends the caller) -- push/pop
 * r4-r9 around the whole body per AAPCS (round 53's lesson: called
 * directly from vani-compiled C, r4-r11 are callee-saved). */
.global dhruva_mutex_unlock
dhruva_mutex_unlock:
    stmdb sp!, {r4-r9, lr}
    mrs r1, cpsr
    cpsid i

    ldr r4, =current_task
    ldr r4, [r4]                     /* r4 = current_task (outgoing owner) */

    /* Restore the outgoing owner's own true priority unconditionally
     * -- undoes any inheritance boost. No nested-mutex stacking (see
     * dhruva_mutex_lock's own header comment). */
    ldr r5, =base_prio_table
    ldr r6, [r5, r4, lsl #2]
    ldr r5, =eff_prio_table
    str r6, [r5, r4, lsl #2]

    ldr r2, =mutex_waiters_table
    ldr r3, [r2, r0, lsl #2]
    cmp r3, #0
    bne dmu_has_waiters

    ldr r5, =mutex_owner_table
    mov r6, #255
    str r6, [r5, r0, lsl #2]         /* owner = unlocked */
    b dmu_done

dmu_has_waiters:
    /* Find the waiting task with the lowest (most urgent) BASE
     * priority among the set bits -- a blocked waiter's own eff_prio
     * entry is never itself boosted (only the OWNER's is, by whoever
     * is waiting on it), so base_prio and eff_prio agree for every
     * waiter; base_prio is used here purely for symmetry with the
     * restore above, not because it differs in practice. */
    ldr r5, =base_prio_table
    mov r6, #255                     /* best prio so far */
    mvn r7, #0                       /* best task index so far (0xFFFFFFFF) */
    mov r8, #0
dmu_scan:
    cmp r8, #16
    bge dmu_scan_done
    mov r9, #1
    lsl r9, r9, r8
    tst r3, r9
    beq dmu_scan_next
    ldr r9, [r5, r8, lsl #2]
    cmp r9, r6
    movlt r6, r9
    movlt r7, r8
dmu_scan_next:
    add r8, r8, #1
    b dmu_scan
dmu_scan_done:
    mov r9, #1
    lsl r9, r9, r7
    bic r3, r3, r9
    str r3, [r2, r0, lsl #2]         /* clear winner's waiter bit */

    ldr r5, =mutex_owner_table
    str r7, [r5, r0, lsl #2]         /* owner = winner */
    ldr r5, =sleep_until_table
    mov r9, #0
    str r9, [r5, r7, lsl #2]         /* winner ready immediately */

    /* Round 59: priority-inversion instrumentation -- compute how long
     * the winner (r7) actually waited (tick_count now minus the tick
     * it blocked at, recorded by dhruva_mutex_lock), and update the
     * worst-case-wait counter if this is the longest yet observed. */
    ldr r5, =mutex_block_start_tick_table
    ldr r6, [r5, r7, lsl #2]
    ldr r5, =tick_count
    ldr r5, [r5]
    sub r6, r5, r6                   /* r6 = wait_ticks */
    ldr r5, =mutex_wait_worst_ticks
    ldr r8, [r5]
    cmp r6, r8
    strgt r6, [r5]

dmu_done:
    msr cpsr_c, r1
    mov r0, #0
    ldmia sp!, {r4-r9, lr}
    bx lr

/* Phase 5 task #1 -- i64 cpu_wfi(): halts instruction fetch until ANY
 * exception is asserted (an IRQ, here -- the 500ms timer tick if
 * nothing else), then resumes at the very next instruction once the
 * interrupt has been taken and serviced, exactly as if it had never
 * paused. Assembles as the ARMv6K hint-space encoding (confirmed via
 * `arm-none-eabi-gcc -mcpu=arm1176jzf-s`'s own disassembly, e320f003 --
 * not the older CP15 `MCR p15,0,Rd,c7,c0,4` sequence some ARMv6
 * implementations need instead), which ARM1176JZF-S implements
 * directly. The real point of this over the idle task's old busy-delay
 * loop: real hardware stops clocking most of the pipeline while
 * halted, which QEMU can't meaningfully validate the wattage of (see
 * DHRUVA_ARCHITECTURE.md §7 Phase 5's own caveat about this), but the
 * *scheduling* effect -- idle genuinely blocking instead of spinning
 * until the next tick -- is real and observable under QEMU too. */
.global cpu_wfi
cpu_wfi:
    wfi
    mov r0, #0
    mov r1, #0
    bx lr

/* i64 mem_barrier() -- ARMv6 data memory barrier (DMB), issued via the
 * CP15 "old" encoding this architecture version uses (ARMv6 predates
 * the dedicated `dmb`/`dsb` mnemonics later architectures have; `mcr
 * p15, 0, Rd, c7, c10, 5` is the documented ARMv6-era equivalent).
 *
 * BUG (round 16 audit, 2026-08-28): needed anywhere this driver writes
 * ordinary memory via plain stores (a DMA buffer, the VideoCore
 * mailbox's own request buffer) and then writes a peripheral register
 * to hand that memory off to a genuinely separate hardware bus master
 * (the DWC2 host controller's own DMA engine, reading dwc2_dma_scratch
 * once HCDMA/HCCHAR are written; the VideoCore, reading governor_
 * mbox_buf once MAILBOX_WRITE is written) that accesses it via its own
 * independent path, not through the CPU at all. This project's own
 * boot.S header comment already documents that the MMU and caches are
 * off for this whole image's lifetime -- but that alone does NOT
 * guarantee write ordering on BCM2835: confirmed against Broadcom's
 * own documented peripheral-access precautions (raspberrypi.com forum
 * t=181306, citing the SoC's own errata/guidance), which state
 * peripheral accesses can complete out of order relative to each
 * other and to normal memory writes -- a property of the AXI bus's
 * multiple-in-flight-transaction model, independent of MMU/cache
 * state -- and explicitly recommend a write barrier before the first
 * write to a peripheral for exactly this "wrote memory, now handing
 * it to hardware" pattern. QEMU's own TCG emulation executes
 * everything in strict program order and never reorders anything, so
 * this entire bug class is invisible under this project's only
 * testing method (confirmed empirically: every DWC2/mailbox self-test
 * already passes without this barrier, under QEMU) -- it would only
 * ever surface as data corruption on real hardware, exactly the kind
 * of gap this project's own "verify against QEMU source, but know
 * what QEMU can't validate" discipline (already applied to DVFS
 * wattage in Phase 5, USB timing here in Phase 6) exists to catch
 * before it ships to a real board.
 *
 * Deliberately NOT applied to every MMIO sequence in this codebase --
 * only the two spots (DWC2's dwc2_control_in/control_no_data,
 * governor_apply_freq_mhz's own mailbox write) where the CPU hands
 * memory IT wrote to a genuinely separate hardware bus master reading
 * it via an independent path. Ordinary peripheral-register-to-
 * register sequences (the SD host command/data-transfer path, GPIO
 * alt-function setup) were flagged as a real, open question for a
 * future round rather than silently left unmentioned, not fixed here.
 *
 * RESOLVED for DWC2's own HPRT0 reset sequence (round 17 audit,
 * 2026-08-28, see dwc2_port_reset's own comment in kernel_main.vani
 * for the full writeup): re-checked against the same Broadcom source
 * this comment already cites, which draws the line precisely --
 * "accesses to the same peripheral will always arrive and return
 * in-order, but it is only when switching from one peripheral to
 * another that data can arrive out-of-order." Every register
 * dwc2_init touches on the way into and through dwc2_port_reset
 * (GSNPSID, GAHBCFG, HPRT0) lives in the one DWC2 IP block at base
 * 0x20980000 -- no cross-peripheral switch ever happens in that path,
 * so no barrier is architecturally required there. Same reasoning
 * closes SDHOST's own command sequence (sdhost_cmd/sdhost_init's CMD0
 * through CMD16, all SDHOST-to-SDHOST, base 0x20202000) -- no fix
 * needed there either.
 *
 * FIXED for round 18's real finding (2026-08-28): GPIO alt-function
 * setup is a genuine, different case from the two resolved above --
 * gpio_uart_alt_init/gpio_sdhost_alt_init each write GPIO registers
 * (base 0x20200000) to mux specific pins onto a DIFFERENT peripheral
 * (PL011 UART / SDHOST), and the caller (uart_init/sdhost_init) then
 * immediately starts driving that other peripheral -- a real
 * cross-peripheral switch, exactly the case Broadcom's guidance says
 * DOES need a barrier. mem_barrier() added at both call sites, right
 * after the GPIO helper returns and before the first register write
 * to the peripheral being muxed for. This is the same class of gap
 * this project already hit for real once before, with a wrong mux
 * VALUE rather than a timing gap around a correct one (see
 * gpio_sdhost_alt_init's own header comment) -- a missing barrier
 * here would fail the same way, just intermittently on real hardware
 * instead of always, and invisible under QEMU either way.
 *
 * FS journaling AUDITED, no barrier question even arises (round 19,
 * 2026-08-28): dharafs_init/dharafs_append/dharafs_compact never touch GPIO or UART
 * at all -- their only hardware dependency is sdhost_read_block/
 * write_block (SDHOST, base 0x20202000), already covered by the
 * SDHOST resolution above; everything else is local .bss state
 * (dharafs_state_*) or UART logging that's pure debug output, not a
 * functional dependency. Round 19's continued sweep of the rest of
 * the boot-time peripheral-init sequence found one more real gap of
 * the same class round 18 fixed: timer_ic_init() (kernel_main.vani)
 * writes the system timer's own match-flag-clear register then
 * immediately writes the interrupt controller's enable register --
 * a cross-peripheral switch this function's own comment says is
 * supposed to guarantee an order ("clear... before enabling"), fixed
 * the same way. uart_rx_irq_init()'s own analogous IMSC-then-
 * IC_ENABLE2 switch was checked and does NOT need the same fix --
 * PL011's interrupt line is level-sensitive (live IMSC & RIS), not a
 * one-shot flag a race could lose, so write order there doesn't
 * affect correctness. watchdog_arm() only ever touches the one PM
 * peripheral (same-peripheral, already covered) and isn't even wired
 * into the live boot path -- not applicable either way. */
.global mem_barrier
mem_barrier:
    mov r0, #0
    mcr p15, 0, r0, c7, c10, 5
    mov r0, #0
    mov r1, #0
    bx lr

/* u32 scheduler_get_tick_count() -- round 22 (2026-08-28): read-only
 * access to this whole scheduler's own notion of elapsed time (see
 * this file's own header comment on tick_count, and irq_entry.S's
 * comment on what actually increments it), needed by DHCP's new
 * lease-renewal timer (kernel_main.vani's dhcp_client_check_lease) to
 * measure elapsed time since a lease was granted. u32, not i64,
 * matching tick_count's own single-word storage and every other
 * scalar accessor in this project's convention of returning a single
 * AAPCS register rather than risking the r0:r1-pairing bug class
 * netif_state.S's netif_set_slot_len hit. Pure read-only
 * introspection, same safety argument as scheduler_ready_count right
 * below: no state changes, no scheduling decision made here, safe to
 * call from any context including an ISR. */
.global scheduler_get_tick_count
scheduler_get_tick_count:
    ldr r0, =tick_count
    ldr r0, [r0]
    bx lr

/* Round 60 crash investigation: diagnostic-only accessor, read from
 * the Data Abort handler to report which task was running at fault
 * time (a fault handler must never assume the corruption it's
 * reporting hasn't also hit heap/stack state, but current_task is a
 * plain, always-valid .bss word -- safe to read unconditionally). */
.global current_task_get
current_task_get:
    ldr r0, =current_task
    ldr r0, [r0]
    bx lr

/* BUG (round 71 audit, 2026-09-05): all five *_get functions below
 * are declared `-> i64` in kernel_main.vani (genuine 64-bit AAPCS
 * return, r0:r1 pair) but only ever set r0 -- found while chasing
 * down a real corrupted-value bug in an unrelated new feature
 * (boot/fb_state.S's own accessors had the identical bug; see that
 * file's own comment for the full root-cause story) and then swept
 * for here too, this codebase's own established discipline after
 * finding one instance of a bug class. Each of these feeds `diagnose`
 * `uart_put_i64` directly -- garbage in r1 could have been silently
 * printing wrong (huge or negative) counter values in `diagnose`'s
 * own output this whole time, masked whenever leftover r1 happened
 * to already be zero. The diag_ring_push call sites for these same
 * three counters were never at risk (they truncate `as u32`, which
 * only ever reads r0). Fixed by explicitly zeroing r1: every one of
 * these counters is a genuine non-negative 32-bit count, so
 * zero-extension is always the correct 64-bit value. */
.global context_switch_count_get
context_switch_count_get:
    ldr r0, =context_switch_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global prio_lock_count_get
prio_lock_count_get:
    ldr r0, =prio_lock_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global mutex_contention_count_get
mutex_contention_count_get:
    ldr r0, =mutex_contention_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global mutex_wait_worst_ticks_get
mutex_wait_worst_ticks_get:
    ldr r0, =mutex_wait_worst_ticks
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global irq_count_increment
irq_count_increment:
    ldr r0, =irq_count
    ldr r1, [r0]
    add r1, r1, #1
    str r1, [r0]
    mov r0, r1
    bx lr

.global irq_count_get
irq_count_get:
    ldr r0, =irq_count
    ldr r0, [r0]
    mov r1, #0
    bx lr



/* TEST-ONLY (round 22, dhcp_renewal_self_test -- not part of any
 * live path): directly sets tick_count, so a boot self-test can
 * stage "N seconds have elapsed since the lease was granted" without
 * either waiting real wall-clock time for real ticks, or subtracting
 * an assumed margin from whatever tick_count happens to already be
 * at self-test time -- which, this early in boot, can genuinely
 * still be 0 or 1, and subtracting from that in u32 space is exactly
 * the kind of underflow this project's own inconsistent overflow
 * trap has hit for real before (see e.g. round 2's eval_apply
 * finding). Safe to mutate directly here specifically because every
 * self-test in this project runs from kernel_main's own single-
 * threaded setup, strictly BEFORE start_multitasking creates any task
 * or unmasks IRQs (see that function's own comment) -- no task's
 * sleep_until_table entry is meaningful yet, and no real timer IRQ
 * can fire concurrently to race this write, so there is no scheduling
 * side effect to worry about. */
.global scheduler_set_tick_count_test_only
scheduler_set_tick_count_test_only:
    ldr r1, =tick_count
    str r0, [r1]
    mov r0, #0
    bx lr

/* i64 scheduler_ready_count() -- Phase 5's run-queue-depth signal for
 * the governor: how many tasks have sleep_until_table[i] <= the
 * current tick_count (i.e. are actually ready right now), not
 * counting idle (task_d, index 3, always ready by design -- see
 * scheduler_pick_next's own comment on why idle must always qualify;
 * counting it would make "ready_count" read as "at least 1" forever,
 * useless as a load signal). Pure read-only introspection, safe to
 * call from any context including an ISR: no state changes, no
 * scheduling decision made here.
 *
 * Round 54: widened to scan all MAX_TASKS=16 slots, and -- UNLIKE
 * scheduler_pick_next, which never needed a fix for this -- this
 * function must explicitly skip an unused slot (eff_prio_table[i] ==
 * 255) too: it only ever looks at sleep_until_table, which an unused
 * slot's own .bss zero-init leaves at 0 (== "always ready"), and
 * would otherwise inflate the count with every never-created slot. */
.global scheduler_ready_count
scheduler_ready_count:
    ldr r1, =tick_count
    ldr r1, [r1]                   /* r1 = tick_count */
    ldr r2, =sleep_until_table
    ldr r6, =eff_prio_table
    mov r3, #0                     /* r3 = count */
    mov r9, #0                     /* r9 = task index */
srq_loop:
    cmp r9, #16                    /* MAX_TASKS */
    bge srq_done
    cmp r9, #3                     /* skip idle (index 3) -- see comment above */
    beq srq_next
    ldr r5, [r6, r9, lsl #2]       /* eff_prio[i] */
    cmp r5, #255
    beq srq_next                   /* unused slot -- skip */
    ldr r4, [r2, r9, lsl #2]       /* sleep_until[i] */
    cmp r4, r1
    addle r3, r3, #1               /* ready if sleep_until[i] <= tick_count */
srq_next:
    add r9, r9, #1
    b srq_loop
srq_done:
    mov r0, r3
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
    /* Round 68: explicit 17-word (68-byte) frame -- see irq_entry.S's
     * own header comment for the full "why" (true_lr vs resume_pc
     * split). A freshly-launched task has no meaningful "true_lr" of
     * its own yet (it never legitimately returns to anything via a
     * live r14), but the slot must still exist so the shared restore
     * code's fixed-size ldm reads a consistent layout -- entry point
     * duplicated into both words, same harmless pattern task_sleep_
     * ticks/dhruva_mutex_lock use for their own voluntary switches. */
    sub r0, r0, #68
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
    str r1, [r0, #60]      /* true_lr = entry point */
    str r1, [r0, #64]      /* resume_pc = entry point */
    bx lr

/* Round 54 -- general task-creation API. Verified BEFORE writing this
 * that vani genuinely supports function pointers as real, first-class
 * values through both backends (a throwaway spike compiled a `fn() ->
 * i64` parameter all the way through vanic's LLVM path to a real ARM
 * `blx r0` indirect call, not just the C backend) -- so unlike the
 * existing task_a-f_init_stack functions above (each hardcoding its
 * own entry point via `ldr r1, =task_X`), this takes the entry point
 * as a genuine runtime argument and works for ANY vani function, not
 * just the 6 built in at compile time.
 *
 * mut ref i64 task_generic_init_stack(fn() -> i64 entry_fn,
 *                                       mut ref i64 stack_base,
 *                                       u32 stack_bytes)
 * entry_fn (a function pointer -- one register, no AAPCS i64-pairing
 * concern) -> r0; stack_base -> r1; stack_bytes (u32, deliberately not
 * i64, for the exact same reason -- see dharafs_buf.S's own file
 * comment on why every parameter there is u32) -> r2. Rearranges into
 * prepare_stack_common's own expected r0=stack_top/r1=entry_addr
 * shape and tail-calls it. */
.global task_generic_init_stack
task_generic_init_stack:
    add r1, r1, r2          /* r1 = stack_base + stack_bytes = stack top */
    mov r3, r0               /* stash entry_fn (r0 is about to be
                               * reused for prepare_stack_common's own
                               * r0=stack_top convention) */
    mov r0, r1               /* r0 = stack top */
    mov r1, r3               /* r1 = entry point */
    b prepare_stack_common

/* void task_table_init()
 * Seeds the 10 free slots (indices 6-15, task_create's own) of
 * eff_prio_table with the "unused" sentinel (255) -- .bss's own
 * zero-init would otherwise leave them at 0, which looks like a
 * real, ready, HIGHEST-priority task and would crash the instant
 * the scheduler ever tried to switch to that slot's uninitialized
 * stack pointer before any real task_create() call.
 *
 * MUST be called exactly once, before the FIRST task_create() call
 * and before start_multitasking (kernel_main.vani's boot sequence
 * does both). This used to be inlined directly into
 * start_multitasking, which is too late: kernel_main.vani calls
 * task_create() during its own boot-time setup, before
 * start_multitasking ever runs -- task_create's scan for the 255
 * sentinel found nothing (slots still read .bss's zeroed 0) and
 * always returned "no free slot" (0xFFFFFFFF), even though no slot
 * was actually taken. A second version of this fix that instead
 * left the seeding inside start_multitasking AND called it again
 * here would have been worse: it would silently overwrite any task
 * already created by a pre-start_multitasking task_create() call,
 * wiping out a live task's table entry. Splitting this into its own
 * one-shot function, called exactly once from kernel_main.vani
 * before anything else touches eff_prio_table, avoids both bugs. */
.global task_table_init
task_table_init:
    ldr r0, =eff_prio_table
    mov r1, #255
    mov r2, #6
ttinit_loop:
    cmp r2, #16
    bge ttinit_done
    str r1, [r0, r2, lsl #2]
    add r2, r2, #1
    b ttinit_loop
ttinit_done:
    // Round 55: also seed mutex_owner_table's MAX_MUTEXES slots to the
    // same 255 "unlocked" sentinel -- r1 still holds 255 from above.
    ldr r0, =mutex_owner_table
    mov r2, #0
ttinit_mutex_loop:
    cmp r2, #MAX_MUTEXES
    bge ttinit_mutex_done
    str r1, [r0, r2, lsl #2]
    add r2, r2, #1
    b ttinit_mutex_loop
ttinit_mutex_done:
    bx lr

/* u32 task_create(fn() -> i64 entry_fn, mut ref i64 stack_base,
 *                  u32 stack_bytes, u32 priority)
 * Finds a free slot (indices 6-15 -- 0-5 stay reserved for the fixed
 * HIGH/MEDIUM/LOW/IDLE/GC/SHELL set), builds the new task's initial
 * context via task_generic_init_stack above, and publishes it into
 * the scheduler's own tables. Returns the new task's index, or
 * 0xFFFFFFFF (u32 -1) if every slot is already taken.
 *
 * All four parameters are single registers (fn pointer, ref, and two
 * u32s -- deliberately not i64, same AAPCS-pairing-avoidance reasoning
 * as task_generic_init_stack above), so this is a completely ordinary
 * r0-r3 call with no stack-spilled arguments to get wrong.
 *
 * Safe to call after start_multitasking (i.e. from a running task,
 * not just at boot): the whole scan-and-publish sequence runs with
 * IRQs masked, so a concurrent scheduler_pick_next (from a timer tick
 * on any other core -- moot on this single-core target, but same
 * discipline as every other shared-table mutation in this file) can
 * never observe a half-published slot. */
.global task_create
task_create:
    stmdb sp!, {r4-r9, lr}
    mov r4, r0              /* entry_fn */
    mov r5, r1              /* stack_base */
    mov r6, r2              /* stack_bytes */
    mov r7, r3              /* priority */

    mrs r8, cpsr
    cpsid i

    ldr r0, =eff_prio_table
    mov r9, #6               /* first free-slot candidate */
tc_scan_loop:
    cmp r9, #16              /* MAX_TASKS */
    bge tc_no_slot
    ldr r1, [r0, r9, lsl #2]
    cmp r1, #255
    beq tc_found_slot
    add r9, r9, #1
    b tc_scan_loop
tc_no_slot:
    msr cpsr_c, r8
    mvn r0, #0                /* u32 -1 == 0xFFFFFFFF: no free slot */
    ldmia sp!, {r4-r9, lr}
    bx lr
tc_found_slot:
    mov r0, r4                /* entry_fn */
    mov r1, r5                /* stack_base */
    mov r2, r6                /* stack_bytes */
    bl task_generic_init_stack
    /* r0 = new task's initial sp; r9 is callee-saved across `bl` per
     * AAPCS, so it still holds the free slot index found above */

    ldr r1, =sp_table
    str r0, [r1, r9, lsl #2]
    ldr r1, =eff_prio_table
    str r7, [r1, r9, lsl #2]
    ldr r1, =base_prio_table   /* Round 55: mirror eff_prio_table's own
                                * store exactly -- this is the task's
                                * TRUE priority, restored by dhruva_
                                * mutex_unlock after any inheritance
                                * boost */
    str r7, [r1, r9, lsl #2]
    ldr r1, =sleep_until_table
    mov r2, #0
    str r2, [r1, r9, lsl #2]   /* explicitly ready immediately -- .bss
                                * zero-init already gives this for a
                                * never-before-used slot, but set it
                                * explicitly rather than rely on that,
                                * since there's no task-deletion API to
                                * reason about reuse safety for yet */

    msr cpsr_c, r8
    mov r0, r9                 /* return the new task's slot index */
    ldmia sp!, {r4-r9, lr}
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
                               * them rotate fairly (round 75) rather
                               * than always favoring one, though in
                               * practice both are normally sleeping
                               * and rarely contend at the same instant
                               * anyway */
    mov r7, #4
    str r7, [r6, #12]        /* task 3 (IDLE) priority 4 -- worst,
                               * as always */

    // Round 55: mirror the exact same 6 stores into base_prio_table --
    // each fixed task's TRUE priority, restored by dhruva_mutex_unlock
    // after any inheritance boost (eff_prio_table's own value can be
    // temporarily boosted; base_prio_table's never is).
    ldr r6, =base_prio_table
    mov r7, #0
    str r7, [r6, #0]
    mov r7, #1
    str r7, [r6, #4]
    mov r7, #2
    str r7, [r6, #8]
    mov r7, #3
    str r7, [r6, #16]
    str r7, [r6, #20]
    mov r7, #4
    str r7, [r6, #12]

    // Round 54: indices 6-15 (task_create's free slots) are NOT
    // touched here -- task_table_init() (see its own comment above)
    // already seeded them to the 255 "unused" sentinel, and must run
    // before this function so that any task_create() call made
    // during kernel_main.vani's own boot sequence (before
    // start_multitasking) sees real free slots. Re-seeding here would
    // clobber whatever task_create already published into a slot.

    ldr r6, =current_task
    mov r7, #0
    str r7, [r6]

    mov sp, r0
    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr, pc}^     /* see irq_entry.S's own restore
                                     * comment for why {lr,pc}^ replaces
                                     * the old {lr} + subs pc,lr,#0 */
