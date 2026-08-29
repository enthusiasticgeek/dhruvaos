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
 * the governor: how many of the 6 tasks have sleep_until_table[i] <=
 * the current tick_count (i.e. are actually ready right now), not
 * counting idle (task_d, index 3, always ready by design -- see
 * scheduler_pick_next's own comment on why idle must always qualify;
 * counting it would make "ready_count" read as "at least 1" forever,
 * useless as a load signal). Pure read-only introspection, safe to
 * call from any context including an ISR: no state changes, no
 * scheduling decision made here. */
.global scheduler_ready_count
scheduler_ready_count:
    ldr r1, =tick_count
    ldr r1, [r1]                   /* r1 = tick_count */
    ldr r2, =sleep_until_table
    mov r3, #0                     /* r3 = count */
    mov r9, #0                     /* r9 = task index */
srq_loop:
    cmp r9, #6
    bge srq_done
    cmp r9, #3                     /* skip idle (index 3) -- see comment above */
    beq srq_next
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
