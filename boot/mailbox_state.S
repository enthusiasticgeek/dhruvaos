/* Dhruva -- generic inter-task mailbox (ARM32).
 *
 * Provenance note: this file was first drafted by a research subagent
 * during an earlier round of this same session, working outside its
 * actual (read-only research) brief -- see docs/TODO.md's own task
 * #240 writeup for the full incident. Unlike that agent's OTHER
 * unrequested edit (unverified assembly written directly into
 * boot/irq_entry.S's IRQ-return path, found broken at link time,
 * reverted entirely), this file is pure new state with no
 * modification to any existing fragile code -- independently
 * reviewed line-by-line before being adopted here, not trusted as-is.
 * One real discrepancy found and fixed in that review: the header
 * below originally claimed an "i64" payload while the accessors
 * themselves only ever move 32 bits -- corrected.
 *
 * Task #249, following a direct comparison of DhruvaOS against NASA's
 * own RTOS-101 checklist (IV&V Facility, Kowalski/Huy): "Inter-task
 * Communication" and "Message Management" are both listed as required
 * RTOS task services. DhruvaOS already has synchronization
 * (dhruva_prio_lock/dhruva_mutex_lock) and one FS-SPECIFIC priority
 * queue (fsqueue_state.S), but no generic message-passing primitive
 * any two tasks can use to exchange data. This closes that gap.
 *
 * Deliberately NON-BLOCKING (poll-based), matching this project's own
 * established idiom for every other background-drain pattern here
 * (task_fsq draining fsqueue, task_e draining DharaFS compaction) --
 * a blocking receive would need real scheduler integration (a new
 * per-task wait-queue, wake-on-message logic in context_switch.S),
 * genuinely larger and riskier scope than this task's own remit.
 * Documented as a real, honest limitation, not a bug: a task that
 * needs to block waiting for a message today combines
 * mailbox_has_message() with its own task_sleep_ticks(...) polling
 * loop, the same pattern task_fsq/task_e already use for their own
 * background work.
 *
 * 8 slots fixed (static-allocation-everywhere discipline, matching
 * fsqueue's own choice), each payload a single u32 (found and fixed
 * during independent review, 2026-09-18: the original draft's own
 * header comment claimed "i64," but mailbox_payload_get_at/_set_at
 * below only ever do a single 32-bit ldr/str -- corrected here to
 * describe what the code actually does, not what a stale comment
 * claimed) -- generic enough for a task index, a small integer
 * command code, or a pointer/offset into shared kernel-domain memory;
 * a wider or multi-word payload was deliberately scoped out (no real
 * workload has needed it yet, same "don't fabricate a need"
 * discipline used throughout this project).
 *
 * Same 2-argument-accessor + caller-computed-combined-index
 * discipline as every other state file here (this project's AAPCS
 * callee-saved-register bug class -- i64 returns go out via r0:r1,
 * so every accessor explicitly zeroes r1 on the way out). */

.section ".bss"
.align 4
mailbox_valid:
    .space 32   /* 8 words */
mailbox_sender_task_id:
    .space 32
mailbox_dest_task_id:
    .space 32
mailbox_priority:
    .space 32
mailbox_seq:
    .space 32
mailbox_payload:
    .space 32
mailbox_next_seq:
    .word 0

.section ".text"

.global mailbox_valid_get_at
mailbox_valid_get_at:
    ldr r1, =mailbox_valid
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global mailbox_valid_set_at
mailbox_valid_set_at:
    ldr r2, =mailbox_valid
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global mailbox_sender_task_id_get_at
mailbox_sender_task_id_get_at:
    ldr r1, =mailbox_sender_task_id
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global mailbox_sender_task_id_set_at
mailbox_sender_task_id_set_at:
    ldr r2, =mailbox_sender_task_id
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global mailbox_dest_task_id_get_at
mailbox_dest_task_id_get_at:
    ldr r1, =mailbox_dest_task_id
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global mailbox_dest_task_id_set_at
mailbox_dest_task_id_set_at:
    ldr r2, =mailbox_dest_task_id
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global mailbox_priority_get_at
mailbox_priority_get_at:
    ldr r1, =mailbox_priority
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global mailbox_priority_set_at
mailbox_priority_set_at:
    ldr r2, =mailbox_priority
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global mailbox_seq_get_at
mailbox_seq_get_at:
    ldr r1, =mailbox_seq
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global mailbox_seq_set_at
mailbox_seq_set_at:
    ldr r2, =mailbox_seq
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global mailbox_payload_get_at
mailbox_payload_get_at:
    ldr r1, =mailbox_payload
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global mailbox_payload_set_at
mailbox_payload_set_at:
    ldr r2, =mailbox_payload
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global mailbox_next_seq_get
mailbox_next_seq_get:
    ldr r0, =mailbox_next_seq
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global mailbox_next_seq_set
mailbox_next_seq_set:
    ldr r1, =mailbox_next_seq
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
