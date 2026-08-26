/* Dhruva Phase 3 -- tiny persistent filesystem state (ARM32).
 *
 * Same shape of problem as sdcard_state.S's RCA/is_sdhc: fs_init()'s
 * recovery scan runs once and needs its result (where the log's
 * append cursor currently sits, and the highest sequence number seen)
 * to reach every later fs_append call, including from a future GC/
 * compaction task's own function body (task #5). No top-level vani
 * global exists to hold them instead.
 *
 * Deliberately NOT persisted to the SD card itself, only to RAM: that
 * would just move the same "how do we know this was written
 * atomically" problem one level down without solving it. The actual
 * source of truth is always the log's own contents -- fs_init()
 * reconstructs both of these values by scanning it, every boot,
 * exactly so a crash mid-write (this project's actual concern, tested
 * by test/power_yank.py) can never leave stale in-RAM bookkeeping
 * trusted over what the card actually holds. */

.section ".bss"
.align 4
fs_next_block:
    .word 0        /* first never-written block -- where the next
                     * fs_append lands; block 0 itself is reserved,
                     * so fs_init() always leaves this at >= 1 */
fs_next_seq:
    .word 0        /* one past the highest sequence number found
                     * during recovery -- guarantees every future
                     * append's sequence number is a genuine new
                     * high, even across many reboots */

.section ".text"

.global fs_state_set
fs_state_set:
    ldr r2, =fs_next_block
    str r0, [r2]
    ldr r2, =fs_next_seq
    str r1, [r2]
    mov r0, #0
    bx lr

.global fs_state_get_next_block
fs_state_get_next_block:
    ldr r0, =fs_next_block
    ldr r0, [r0]
    bx lr

.global fs_state_get_next_seq
fs_state_get_next_seq:
    ldr r0, =fs_next_seq
    ldr r0, [r0]
    bx lr
