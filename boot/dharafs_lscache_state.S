/* Bare "ls" (dharafs_list("")) result cache (2026-11-21).
 *
 * Why: dharafs_list has no directory index at all -- every single call
 * does a full linear scan of every block from log_start to next_block,
 * with NO memoization between calls. On a healthy card that's cheap
 * enough not to matter, but a real-HW incident this round showed it
 * can also pay the full multi-attempt retry-ladder cost (tens of
 * seconds) on every newly-bad block it crosses -- and a second `ls`
 * issued moments later, with ZERO writes in between, redid the exact
 * same multi-hour scan from scratch for no reason. This cache fixes
 * that specific waste without touching the bad-block classification
 * policy at all (see kernel_main.vani's dharafs_badblock_report_failure
 * for that separate, deliberately conservative mechanism).
 *
 * Deliberately scoped to ONLY the bare "ls" case (prefix_len == 0):
 * that's the call shape that actually bit us, and it means the cache
 * key needs no stored prefix string -- just whether the scan's own
 * input range changed. dharafs_list(prefix) with a non-empty prefix,
 * and dharafs_list_dir_raw (the `ls <dir>` / path-classify sibling),
 * always do a real scan unchanged; they're candidates for the same
 * treatment later if this turns out to matter in practice too.
 *
 * Invalidation is just "did the scanned range change": log_start and
 * next_block together define exactly what dharafs_list's own loop
 * walks, so a cache entry is valid iff both still match the values
 * last captured under -- any real append moves next_block, any
 * compaction/rotation moves log_start, so this can never serve a
 * stale listing. No separate dirty flag or generation counter needed.
 *
 * 4096-byte capture buffer, matching dharafs_log_existing_scratch's
 * own precedent for "a generously-sized single scratch region" in
 * this file family. If one bare-ls listing's printed output would
 * ever exceed that (a card with an unusually large number of live
 * files), capturing is simply abandoned for that pass (dharafs_
 * lscache_overflow) and valid is left clear -- the real scan's own
 * direct-to-UART prints are completely unaffected either way, so an
 * oversized listing still prints correctly, it's just never cached. */

.section ".bss"
.align 4
dharafs_lscache_buf_addr:
    .word 0        /* set once at boot via dharafs_lscache_buf_set,
                     * to a 4096-byte dhruva_alloc_bytes buffer */
dharafs_lscache_valid:
    .word 0
dharafs_lscache_capturing:
    .word 0
dharafs_lscache_overflow:
    .word 0
dharafs_lscache_log_start:
    .word 0
dharafs_lscache_next_block:
    .word 0
dharafs_lscache_byte_len:
    .word 0

.section ".text"
.align 4

.global dharafs_lscache_buf_set
dharafs_lscache_buf_set:
    ldr r1, =dharafs_lscache_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_lscache_buf_get
dharafs_lscache_buf_get:
    ldr r0, =dharafs_lscache_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global dharafs_lscache_valid_set
dharafs_lscache_valid_set:
    ldr r1, =dharafs_lscache_valid
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_lscache_valid_get
dharafs_lscache_valid_get:
    ldr r0, =dharafs_lscache_valid
    ldr r0, [r0]
    bx lr

.global dharafs_lscache_capturing_set
dharafs_lscache_capturing_set:
    ldr r1, =dharafs_lscache_capturing
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_lscache_capturing_get
dharafs_lscache_capturing_get:
    ldr r0, =dharafs_lscache_capturing
    ldr r0, [r0]
    bx lr

.global dharafs_lscache_overflow_set
dharafs_lscache_overflow_set:
    ldr r1, =dharafs_lscache_overflow
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_lscache_overflow_get
dharafs_lscache_overflow_get:
    ldr r0, =dharafs_lscache_overflow
    ldr r0, [r0]
    bx lr

.global dharafs_lscache_log_start_set
dharafs_lscache_log_start_set:
    ldr r1, =dharafs_lscache_log_start
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_lscache_log_start_get
dharafs_lscache_log_start_get:
    ldr r0, =dharafs_lscache_log_start
    ldr r0, [r0]
    bx lr

.global dharafs_lscache_next_block_set
dharafs_lscache_next_block_set:
    ldr r1, =dharafs_lscache_next_block
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_lscache_next_block_get
dharafs_lscache_next_block_get:
    ldr r0, =dharafs_lscache_next_block
    ldr r0, [r0]
    bx lr

.global dharafs_lscache_byte_len_set
dharafs_lscache_byte_len_set:
    ldr r1, =dharafs_lscache_byte_len
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_lscache_byte_len_get
dharafs_lscache_byte_len_get:
    ldr r0, =dharafs_lscache_byte_len
    ldr r0, [r0]
    bx lr
