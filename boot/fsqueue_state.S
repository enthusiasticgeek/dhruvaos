/* Dhruva -- priority-aware DharaFS request queue (ARM32).
 *
 * Every dharafs_* call today runs synchronously inline in whatever
 * task called it -- there's no queue for a higher-priority task's I/O
 * to precede a lower-priority one's. This is a genuine, bounded,
 * OPT-IN queue: dharafs_queue_submit_write/_delete (kernel_main.vani)
 * enqueue a request tagged with the calling task's own effective
 * priority (current_eff_prio()); a dedicated low-priority background
 * task (task_fsq) drains it one entry at a time, always picking the
 * numerically LOWEST priority value (this project's own "0 is
 * highest" convention, same as the scheduler itself), oldest-first
 * among ties (the seq field), through the exact same crash-safe
 * dharafs_append_raw/dharafs_delete_raw every existing direct call
 * already uses. Every EXISTING synchronous call site is completely
 * unchanged -- this is additive, not a replacement.
 *
 * 8 slots fixed (static-allocation-everywhere discipline, same as
 * every other fixed-size table in this project); each queued write's
 * data is capped at dharafs_block_payload_cap() (448 bytes) -- a
 * queued op is deliberately single-block-sized only, matching the
 * "no current workload actually needs this yet" honest scoping in
 * docs/TODO.md; anything larger still just calls dharafs_append_raw
 * directly/synchronously as today.
 *
 * Same 2-argument-accessor + caller-computed-combined-index
 * discipline as every other state file here (this project's AAPCS
 * callee-saved-register bug class). */

.section ".bss"
.align 4
fsqueue_valid:
    .space 32   /* 8 words */
fsqueue_priority:
    .space 32
fsqueue_task_id:
    .space 32
fsqueue_op_type:
    .space 32   /* 1 = write/append, 2 = delete */
fsqueue_path_len:
    .space 32
fsqueue_data_len:
    .space 32
fsqueue_owner_uid:
    .space 32
fsqueue_owner_gid:
    .space 32
fsqueue_mode:
    .space 32
fsqueue_seq:
    .space 32
fsqueue_result:
    .space 32
fsqueue_next_seq:
    .word 0
fsqueue_path_bytes:
    .space 256  /* 8 slots * 32 bytes */
fsqueue_data_bytes:
    .space 3584 /* 8 slots * 448 bytes */

.section ".text"

.global fsqueue_valid_get_at
fsqueue_valid_get_at:
    ldr r1, =fsqueue_valid
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_valid_set_at
fsqueue_valid_set_at:
    ldr r2, =fsqueue_valid
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_priority_get_at
fsqueue_priority_get_at:
    ldr r1, =fsqueue_priority
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_priority_set_at
fsqueue_priority_set_at:
    ldr r2, =fsqueue_priority
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_task_id_get_at
fsqueue_task_id_get_at:
    ldr r1, =fsqueue_task_id
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_task_id_set_at
fsqueue_task_id_set_at:
    ldr r2, =fsqueue_task_id
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_op_type_get_at
fsqueue_op_type_get_at:
    ldr r1, =fsqueue_op_type
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_op_type_set_at
fsqueue_op_type_set_at:
    ldr r2, =fsqueue_op_type
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_path_len_get_at
fsqueue_path_len_get_at:
    ldr r1, =fsqueue_path_len
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_path_len_set_at
fsqueue_path_len_set_at:
    ldr r2, =fsqueue_path_len
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_data_len_get_at
fsqueue_data_len_get_at:
    ldr r1, =fsqueue_data_len
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_data_len_set_at
fsqueue_data_len_set_at:
    ldr r2, =fsqueue_data_len
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_owner_uid_get_at
fsqueue_owner_uid_get_at:
    ldr r1, =fsqueue_owner_uid
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_owner_uid_set_at
fsqueue_owner_uid_set_at:
    ldr r2, =fsqueue_owner_uid
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_owner_gid_get_at
fsqueue_owner_gid_get_at:
    ldr r1, =fsqueue_owner_gid
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_owner_gid_set_at
fsqueue_owner_gid_set_at:
    ldr r2, =fsqueue_owner_gid
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_mode_get_at
fsqueue_mode_get_at:
    ldr r1, =fsqueue_mode
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_mode_set_at
fsqueue_mode_set_at:
    ldr r2, =fsqueue_mode
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_seq_get_at
fsqueue_seq_get_at:
    ldr r1, =fsqueue_seq
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_seq_set_at
fsqueue_seq_set_at:
    ldr r2, =fsqueue_seq
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_result_get_at
fsqueue_result_get_at:
    ldr r1, =fsqueue_result
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global fsqueue_result_set_at
fsqueue_result_set_at:
    ldr r2, =fsqueue_result
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global fsqueue_next_seq_get
fsqueue_next_seq_get:
    ldr r0, =fsqueue_next_seq
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global fsqueue_next_seq_set
fsqueue_next_seq_set:
    ldr r1, =fsqueue_next_seq
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

/* i64 fsqueue_get_path_byte(i64 combined_index) -- caller (vani)
 * computes combined_index = slot*32 + byte_offset. */
.global fsqueue_get_path_byte
fsqueue_get_path_byte:
    ldr r1, =fsqueue_path_bytes
    ldrb r0, [r1, r0]
    mov r1, #0
    bx lr

.global fsqueue_set_path_byte
fsqueue_set_path_byte:
    ldr r2, =fsqueue_path_bytes
    strb r1, [r2, r0]
    mov r0, #0
    mov r1, #0
    bx lr

/* i64 fsqueue_get_data_byte(i64 combined_index) -- combined_index =
 * slot*448 + byte_offset. */
.global fsqueue_get_data_byte
fsqueue_get_data_byte:
    ldr r1, =fsqueue_data_bytes
    ldrb r0, [r1, r0]
    mov r1, #0
    bx lr

.global fsqueue_set_data_byte
fsqueue_set_data_byte:
    ldr r2, =fsqueue_data_bytes
    strb r1, [r2, r0]
    mov r0, #0
    mov r1, #0
    bx lr
