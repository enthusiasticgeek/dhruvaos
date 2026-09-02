/* Dhruva round 66 -- self-observing kernel's own "last N seconds"
 * event-history ring buffer (docs/TODO.md's own "Self-observing
 * kernel: event counters" entry, the one genuinely separate piece
 * left after round 53's running-total counters).
 *
 * DELIBERATELY does NOT touch boot/context_switch.S: context_switch_
 * count and prio_lock_count are incremented deep inside scheduler_
 * pick_next/dhruva_prio_lock, the exact hand-written-asm scheduler/
 * interrupt critical path this project has already suffered two real,
 * hard-to-diagnose bugs in (see feedback_aapcs_callee_saved_registers_
 * asm and project memory on the round-65 task_f corruption bug) --
 * adding new ring-buffer-push logic at those exact sites for a "nice
 * to have" diagnostic feature would be a genuinely disproportionate
 * risk. Instead this samples the EXISTING running totals (via their
 * own already-correct *_get() accessors) once per real timer tick,
 * from kernel_main.vani's irq_dispatch -- already vani-level code that
 * already runs every tick, zero new asm touches to the fragile area
 * at all. Cost: history granularity is one sample per tick (~500ms),
 * not per individual event -- acceptable for a "what was activity
 * like recently" query, the actual stated goal.
 *
 * 32 slots * 500ms/tick = 16 seconds of history, a concrete answer to
 * this TODO entry's own "needs a concrete decision on retention size"
 * blocker -- small enough (4 arrays * 32 words = 512 bytes, .bss, no
 * heap cost at all) that overhead was never really the hard part once
 * a design was picked.
 *
 * Four parallel u32 arrays (tick_count, context_switch_count,
 * irq_count, prio_lock_count at the moment of each sample) rather than
 * one array of structs -- same shape netif_state.S's own per-slot
 * bookkeeping already uses, and keeps every array a flat, independent
 * word-indexed table with no struct-layout arithmetic to get wrong.
 * head/count follow the exact same "mod via AND with size-1" pattern
 * netif_state.S's own advance_head/advance_tail already establish
 * (RING_SIZE=32 is a power of 2 specifically so this works).
 *
 * Physical array access only here -- "which physical slot is logical
 * sample N" (accounting for wraparound once the buffer fills) is
 * deliberately done in vani (diag_ring_read_sample, kernel_main.vani),
 * not here: arithmetic in vani doesn't carry any AAPCS/register-
 * allocation risk at all, so the higher-risk asm layer stays as thin
 * and mechanical as possible.
 */

.section ".bss"
.align 4
diag_ring_tick:
    .space 128    /* 32 words: tick_count at each sample */
diag_ring_ctxsw:
    .space 128    /* 32 words: context_switch_count at each sample */
diag_ring_irqs:
    .space 128    /* 32 words: irq_count at each sample */
diag_ring_priolock:
    .space 128    /* 32 words: prio_lock_count at each sample */
diag_ring_head:
    .word 0       /* next slot a push writes into */
diag_ring_count:
    .word 0       /* how many slots hold a real sample, caps at 32 */

.section ".text"

/* void diag_ring_push(u32 tick, u32 ctxsw, u32 irqs, u32 priolock)
 * All four args are plain u32 (not i64) specifically to keep them each
 * in exactly one AAPCS register (r0-r3) with no 64-bit register-pairing
 * to get wrong -- the documented gotcha (see context_switch_state.S's
 * own task_sleep_ticks comment) only bites i64 arguments. r4/r5 used
 * as scratch below ARE saved/restored (push/pop) -- the exact fix, not
 * just a defensive habit, for the real bug class this project already
 * hit once in this same "small assembly accessor" shape (round 51,
 * see feedback_aapcs_callee_saved_registers_asm): r4-r11 are callee-
 * saved under AAPCS and clobbering them unsaved here would corrupt
 * whatever live value the vani caller (irq_dispatch) trusts to survive
 * this call untouched. */
.global diag_ring_push
diag_ring_push:
    push {r4, r5}
    ldr r12, =diag_ring_head
    ldr r4, [r12]
    ldr r5, =diag_ring_tick
    str r0, [r5, r4, lsl #2]
    ldr r5, =diag_ring_ctxsw
    str r1, [r5, r4, lsl #2]
    ldr r5, =diag_ring_irqs
    str r2, [r5, r4, lsl #2]
    ldr r5, =diag_ring_priolock
    str r3, [r5, r4, lsl #2]
    add r4, r4, #1
    and r4, r4, #31            /* mod 32 -- RING_SIZE is a power of 2 */
    str r4, [r12]
    ldr r12, =diag_ring_count
    ldr r4, [r12]
    cmp r4, #32
    addlt r4, r4, #1
    str r4, [r12]
    pop {r4, r5}
    mov r0, #0
    mov r1, #0
    bx lr

.global diag_ring_get_head
diag_ring_get_head:
    ldr r0, =diag_ring_head
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global diag_ring_get_count
diag_ring_get_count:
    ldr r0, =diag_ring_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

/* i64 diag_ring_get_tick_at(i64 physical_index) -- raw array read, no
 * wraparound logic (that's diag_ring_read_sample's job, in vani). */
.global diag_ring_get_tick_at
diag_ring_get_tick_at:
    ldr r1, =diag_ring_tick
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global diag_ring_get_ctxsw_at
diag_ring_get_ctxsw_at:
    ldr r1, =diag_ring_ctxsw
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global diag_ring_get_irqs_at
diag_ring_get_irqs_at:
    ldr r1, =diag_ring_irqs
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global diag_ring_get_priolock_at
diag_ring_get_priolock_at:
    ldr r1, =diag_ring_priolock
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr
