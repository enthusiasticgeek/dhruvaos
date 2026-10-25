/* Dhruva -- DharaFS in-memory hashed directory index (ARM32).
 *
 * dharafs_find_latest_block_raw (kernel_main.vani) is a full linear
 * scan of the entire live log region on EVERY lookup -- fine at this
 * project's original small scale, but genuinely O(live log size) per
 * open/read/write/stat/delete/rename. This table is a pure, RAM-only
 * accelerator: path-hash -> latest block number, open-addressed with
 * linear probing, 256 slots fixed.
 *
 * REAL-HW FINDING (2026-10-25, DharaFS Phase 2/3 verification): the
 * original header comment here claimed "this project's own realistic
 * file counts are 'tens to low hundreds'" -- live-proven wrong on an
 * actual long-running real-HW card, which accumulated well over 256
 * distinct real paths over one extended test session. Once the table
 * filled, EVERY path that didn't make it into one of the first 256
 * slots was permanently stuck on the slow linear-scan fallback for
 * the rest of that boot (no eviction existed at all -- an insert into
 * a full table was simply skipped, forever, every single lookup).
 * Confirmed live: `cat` on a file written and read back cleanly
 * minutes earlier took several minutes to resolve after a reboot,
 * safely bounded (the watchdog kicks added alongside this fix) but
 * genuinely unusable interactively.
 *
 * Fixed with real LRU eviction instead of "skip forever": dirindex_
 * last_used (one u32 per slot) plus a single global dirindex_clock
 * tick on every hit AND every insert (dharafs_dirindex_find_slot/
 * _upsert, kernel_main.vani) make "which entry hasn't been touched in
 * the longest time" a cheap, well-defined question -- answered by a
 * full scan over just this table's own (RAM-only) slots, several
 * orders of magnitude cheaper than the real-SD-I/O linear scan an
 * eviction avoids forcing the NEXT lookup of some unrelated hot path
 * into. Evicting a slot only ever overwrites ITS OWN hash/pathlen/
 * path-bytes/block/last_used -- every other slot's own findability is
 * completely unaffected (dharafs_dirindex_find_slot's lookup loop
 * already degrades correctly to a full bounded scan once no empty
 * slot remains to stop early at; eviction never invalidates a slot,
 * only repurposes one, so that loop's own correctness proof didn't
 * need to change at all).
 *
 * Never a correctness authority by itself regardless: entries are
 * only ever ADDED, UPDATED, or now EVICTED (dharafs_init's own boot-
 * time scan rebuilds it from scratch; dharafs_append_raw upserts on
 * every successful write, which -- since every path-mutating
 * operation in this codebase funnels through dharafs_append_raw,
 * including delete's tombstone and rename's append half -- covers
 * every case uniformly). A lookup miss always falls back to the
 * original linear scan in kernel_main.vani, which then self-heals the
 * index for next time -- now via eviction instead of a silent no-op
 * once the table is full, so "next time" is no longer a broken
 * promise for a path that lost the race to be among the first 256
 * ever indexed.
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
dirindex_last_used:
    .space 1024  /* 256 words -- dirindex_clock tick stamped on every
                  * hit or insert; the eviction victim on a full table
                  * is whichever slot has the smallest value here. */
dirindex_path_bytes:
    .space 8192  /* 256 slots * 32 bytes max path each, byte-addressed */

.section ".bss"
.align 4
dirindex_clock:
    .word 0  /* monotonic tick, single global counter -- see
              * dirindex_clock_tick below. Wraparound after 2^32 ticks
              * is the same non-concern dharafs_next_seq's own u32
              * already accepts (dharafs_state.S): not reachable in
              * any real session, and even if it were, the comparison
              * this value feeds only needs "which of 256 values is
              * smallest," not a global total order across a wrap. */

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

.global dirindex_get_last_used_at
dirindex_get_last_used_at:
    ldr r1, =dirindex_last_used
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

.global dirindex_set_last_used_at
dirindex_set_last_used_at:
    ldr r2, =dirindex_last_used
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

/* u32 dirindex_clock_tick(void) -- increments the global clock and
 * returns the NEW value in one call, so a caller's "stamp this slot"
 * always gets a value strictly greater than every previously-stamped
 * slot's own value (no caller ever needs to read-then-increment
 * itself, which would risk two callers computing the same "new"
 * value in sequence if that were ever split across two calls). */
.global dirindex_clock_tick
dirindex_clock_tick:
    ldr r0, =dirindex_clock
    ldr r1, [r0]
    add r1, r1, #1
    str r1, [r0]
    mov r0, r1
    bx lr
