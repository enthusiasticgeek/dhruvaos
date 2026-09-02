/* Dhruva -- DharaFS named snapshots (ARM32).
 *
 * A "snapshot" here is simply a NAME pinned to a sequence number
 * (dharafs_state_get_next_seq() at creation time, minus 1 -- the
 * highest seq that genuinely existed at that moment). Nothing about
 * compaction changes: DharaFS's own log (kernel/kernel_main.vani's
 * dharafs_append_raw/dharafs_compact) already never reuses or
 * overwrites a block number within one boot session -- next_block
 * only ever grows, and dharafs_compact's own "reclaim" is an IN-RAM-
 * ONLY optimization (advancing log_start, which unconditionally
 * resets to 1 on the next dharafs_init/boot, see that function's own
 * comment) that skips old blocks for ordinary lookups without ever
 * erasing their bytes on the SD card. So every historical record,
 * for the lifetime of this v1's 2048-block/1MB log region, is
 * ALREADY physically preserved -- a snapshot doesn't need to prevent
 * reclaim, it only needs to remember which sequence number to query
 * against later. dharafs_find_block_as_of_raw (kernel_main.vani)
 * does that query by scanning from block 1 (not log_start), the one
 * place in this codebase that deliberately looks past what log_start
 * currently hides.
 *
 * 8 named slots fixed (this project's own static-allocation
 * discipline, same scale as every other small fixed table here).
 * Same 2-argument-accessor + caller-computed-combined-index
 * discipline as every other state file. */

.section ".bss"
.align 4
snapshot_valid:
    .space 32   /* 8 words */
snapshot_pinned_seq:
    .space 32
snapshot_name_len:
    .space 32
snapshot_name_bytes:
    .space 256  /* 8 slots * 32 bytes */

.section ".text"

.global snapshot_valid_get_at
snapshot_valid_get_at:
    ldr r1, =snapshot_valid
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global snapshot_valid_set_at
snapshot_valid_set_at:
    ldr r2, =snapshot_valid
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global snapshot_pinned_seq_get_at
snapshot_pinned_seq_get_at:
    ldr r1, =snapshot_pinned_seq
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global snapshot_pinned_seq_set_at
snapshot_pinned_seq_set_at:
    ldr r2, =snapshot_pinned_seq
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global snapshot_name_len_get_at
snapshot_name_len_get_at:
    ldr r1, =snapshot_name_len
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global snapshot_name_len_set_at
snapshot_name_len_set_at:
    ldr r2, =snapshot_name_len
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

/* i64 snapshot_get_name_byte(i64 combined_index) -- caller (vani)
 * computes combined_index = slot*32 + byte_offset. */
.global snapshot_get_name_byte
snapshot_get_name_byte:
    ldr r1, =snapshot_name_bytes
    ldrb r0, [r1, r0]
    mov r1, #0
    bx lr

.global snapshot_set_name_byte
snapshot_set_name_byte:
    ldr r2, =snapshot_name_bytes
    strb r1, [r2, r0]
    mov r0, #0
    mov r1, #0
    bx lr
