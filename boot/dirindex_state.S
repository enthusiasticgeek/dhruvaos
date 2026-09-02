/* Dhruva -- DharaFS in-memory hashed directory index (ARM32).
 *
 * dharafs_find_latest_block_raw (kernel_main.vani) is a full linear
 * scan of the entire live log region on EVERY lookup -- fine at this
 * project's original small scale, but genuinely O(live log size) per
 * open/read/write/stat/delete/rename. This table is a pure, RAM-only
 * accelerator: path-hash -> latest block number, open-addressed with
 * linear probing, 256 slots fixed (this project's own realistic file
 * counts are "tens to low hundreds," per docs/TODO.md's own reasoning
 * -- a hash index sized for millions of files would be solving a
 * scaling problem this project doesn't have).
 *
 * Never a correctness authority by itself: entries are only ever
 * ADDED or their block field UPDATED (dharafs_init's own boot-time
 * scan rebuilds it from scratch; dharafs_append_raw upserts on every
 * successful write, which -- since every path-mutating operation in
 * this codebase funnels through dharafs_append_raw, including
 * delete's tombstone and rename's append half -- covers every case
 * uniformly). A lookup miss always falls back to the original linear
 * scan in kernel_main.vani, which then self-heals the index for next
 * time. A full table (256 distinct live paths at once) degrades
 * gracefully to "that one extra path stays on the slow path," never a
 * crash or a wrong answer.
 *
 * Same 2-argument-accessor + caller-computed-combined-index
 * discipline as gatt_server_state.S's own header comment (this
 * project's AAPCS callee-saved-register bug class) -- path bytes use
 * combined_index = slot*32 + byte_offset. */

.section ".bss"
.align 4
dirindex_valid:
    .space 1024  /* 256 words */
dirindex_hash:
    .space 1024
dirindex_pathlen:
    .space 1024
dirindex_block:
    .space 1024
dirindex_path_bytes:
    .space 8192  /* 256 slots * 32 bytes max path each, byte-addressed */

.section ".text"

.global dirindex_get_valid_at
dirindex_get_valid_at:
    ldr r1, =dirindex_valid
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global dirindex_set_valid_at
dirindex_set_valid_at:
    ldr r2, =dirindex_valid
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global dirindex_get_hash_at
dirindex_get_hash_at:
    ldr r1, =dirindex_hash
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global dirindex_set_hash_at
dirindex_set_hash_at:
    ldr r2, =dirindex_hash
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global dirindex_get_pathlen_at
dirindex_get_pathlen_at:
    ldr r1, =dirindex_pathlen
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global dirindex_set_pathlen_at
dirindex_set_pathlen_at:
    ldr r2, =dirindex_pathlen
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

.global dirindex_get_block_at
dirindex_get_block_at:
    ldr r1, =dirindex_block
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global dirindex_set_block_at
dirindex_set_block_at:
    ldr r2, =dirindex_block
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

/* i64 dirindex_get_path_byte(i64 combined_index) -- caller (vani)
 * computes combined_index = slot*32 + byte_offset. */
.global dirindex_get_path_byte
dirindex_get_path_byte:
    ldr r1, =dirindex_path_bytes
    ldrb r0, [r1, r0]
    mov r1, #0
    bx lr

.global dirindex_set_path_byte
dirindex_set_path_byte:
    ldr r2, =dirindex_path_bytes
    strb r1, [r2, r0]
    mov r0, #0
    mov r1, #0
    bx lr
