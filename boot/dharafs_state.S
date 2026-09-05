/* Dhruva Phase 3 -- tiny persistent filesystem state (ARM32).
 *
 * Same shape of problem as sdcard_state.S's RCA/is_sdhc: dharafs_init()'s
 * recovery scan runs once and needs its result (where the log's
 * append cursor currently sits, and the highest sequence number seen)
 * to reach every later dharafs_append call, including from a future GC/
 * compaction task's own function body (task #5). No top-level vani
 * global exists to hold them instead.
 *
 * Deliberately NOT persisted to the SD card itself, only to RAM: that
 * would just move the same "how do we know this was written
 * atomically" problem one level down without solving it. The actual
 * source of truth is always the log's own contents -- dharafs_init()
 * reconstructs both of these values by scanning it, every boot,
 * exactly so a crash mid-write (this project's actual concern, tested
 * by test/power_yank.py) can never leave stale in-RAM bookkeeping
 * trusted over what the card actually holds. */

.section ".bss"
.align 4
dharafs_next_block:
    .word 0        /* first never-written block -- where the next
                     * dharafs_append lands; block 0 itself is reserved,
                     * so dharafs_init() always leaves this at >= 1 */
dharafs_next_seq:
    .word 0        /* one past the highest sequence number found
                     * during recovery -- guarantees every future
                     * append's sequence number is a genuine new
                     * high, even across many reboots */
dharafs_log_start:
    .word 0        /* first block still scanned/trusted; task #5's
                     * compaction moves this forward past blocks whose
                     * every record has a newer copy beyond it. dharafs_init
                     * always sets this back to 1 (block 0 reserved) --
                     * NOT persisted to the card itself in this v1, so
                     * a crash before the next successful compaction
                     * just means recovery re-scans a prefix it could
                     * have skipped, never a correctness problem, only
                     * a lost optimization for that one boot. */
dharafs_current_uid:
    .word 0        /* Round 42: the active user ID for permission
                     * checks (dharafs_check_permission in kernel_main.vani).
                     * .bss zero-init means uid 0 (root/superuser) by
                     * default -- Dhruva has no login yet, so this is
                     * both "the only user that exists today" and "the
                     * user that bypasses all permission checks",
                     * exactly like a real Unix system's root account.
                     * dharafs_user_set lets a caller (a self-test, or a
                     * future real multi-user shell) switch context. */
dharafs_current_gid:
    .word 0        /* Round 42: the active group ID, same role as
                     * dharafs_current_uid above. */
dharafs_block_dev:
    .word 0        /* Round 36: which block-device backend dharafs_block_
                     * read/dharafs_block_write (kernel_main.vani) dispatch
                     * to -- 0 = SDHOST (the permanent default for
                     * every normal FS operation: boot self-tests,
                     * shell ls/cat/write, phase4_milestone.py), 1 =
                     * USB mass storage (rounds 33-35's own real,
                     * live-proven READ(10)/WRITE(10)). .bss zero-init
                     * means SDHOST is exactly what every existing FS
                     * call gets with zero behavior change -- this is
                     * purely additive, not a default switch. Only
                     * dharafs_block_dev_self_check (kernel_main.vani)
                     * temporarily flips this to prove the USB backend
                     * actually works through the same abstraction,
                     * then restores it before any real FS operation
                     * runs. */
dharafs_commit_count:
    .word 0        /* Round 51: total number of successful dharafs_
                     * block_write calls this boot -- a cheap, always-
                     * available "how much has DharaFS actually
                     * written" counter for kernel_main.vani's
                     * `diagnose` command. Incremented from vani code
                     * (dharafs_block_write) via dharafs_commit_count_
                     * increment below, not automatically -- this file
                     * has no way to hook the write call itself. */
dharafs_compact_resume_block:
    .word 0        /* Round 77: docs/RTOS_GAP_ANALYSIS.md's own
                     * "dharafs_compact() has unbounded worst-case
                     * cost" gap -- its main scan loop used to run from
                     * log_start all the way to next_block in ONE call,
                     * a real SD I/O operation per block, cost scaling
                     * with however much log has accumulated since the
                     * last pass. This is the resume cursor that makes
                     * it bounded-per-call instead: 0 means "no partial
                     * pass in progress, start fresh from log_start"
                     * (block 0 is reserved/never a real scan target,
                     * see dharafs_next_block's own comment, so it's a
                     * safe sentinel); any other value is the next
                     * block a PRIOR call didn't get to yet within its
                     * own per-call block budget. */
dharafs_compact_failed:
    .word 0        /* Round 77: sticky "did any carry-forward fail
                     * during the pass currently in progress" flag --
                     * must persist ACROSS resumed calls (unlike the
                     * local `all_ok` a single call's own scan uses),
                     * since a failure in an early partial call must
                     * still correctly block log_start from advancing
                     * once the whole range finally finishes scanning,
                     * potentially many calls later. Reset to 0 only
                     * when a genuinely FRESH pass starts (resume
                     * cursor was 0), so an old pass's failure can
                     * never leak into a new one. */

.section ".text"

.global dharafs_state_set
dharafs_state_set:
    ldr r2, =dharafs_next_block
    str r0, [r2]
    ldr r2, =dharafs_next_seq
    str r1, [r2]
    mov r0, #0
    bx lr

.global dharafs_state_get_next_block
dharafs_state_get_next_block:
    ldr r0, =dharafs_next_block
    ldr r0, [r0]
    bx lr

.global dharafs_state_get_next_seq
dharafs_state_get_next_seq:
    ldr r0, =dharafs_next_seq
    ldr r0, [r0]
    bx lr

.global dharafs_state_set_log_start
dharafs_state_set_log_start:
    ldr r1, =dharafs_log_start
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_state_get_log_start
dharafs_state_get_log_start:
    ldr r0, =dharafs_log_start
    ldr r0, [r0]
    bx lr

.global dharafs_compact_set_resume_block
dharafs_compact_set_resume_block:
    ldr r1, =dharafs_compact_resume_block
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_compact_get_resume_block
dharafs_compact_get_resume_block:
    ldr r0, =dharafs_compact_resume_block
    ldr r0, [r0]
    bx lr

.global dharafs_compact_set_failed
dharafs_compact_set_failed:
    ldr r1, =dharafs_compact_failed
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_compact_get_failed
dharafs_compact_get_failed:
    ldr r0, =dharafs_compact_failed
    ldr r0, [r0]
    bx lr

.global dharafs_state_set_block_dev
dharafs_state_set_block_dev:
    ldr r1, =dharafs_block_dev
    str r0, [r1]
    mov r0, #0
    bx lr

.global dharafs_state_get_block_dev
dharafs_state_get_block_dev:
    ldr r0, =dharafs_block_dev
    ldr r0, [r0]
    bx lr

.global dharafs_user_set
dharafs_user_set:
    ldr r2, =dharafs_current_uid
    str r0, [r2]
    ldr r2, =dharafs_current_gid
    str r1, [r2]
    mov r0, #0
    bx lr

.global dharafs_user_get_uid
dharafs_user_get_uid:
    ldr r0, =dharafs_current_uid
    ldr r0, [r0]
    bx lr

.global dharafs_user_get_gid
dharafs_user_get_gid:
    ldr r0, =dharafs_current_gid
    ldr r0, [r0]
    bx lr

.global dharafs_commit_count_increment
dharafs_commit_count_increment:
    ldr r0, =dharafs_commit_count
    ldr r1, [r0]
    add r1, r1, #1
    str r1, [r0]
    mov r0, r1
    bx lr

.global dharafs_commit_count_get
dharafs_commit_count_get:
    ldr r0, =dharafs_commit_count
    ldr r0, [r0]
    bx lr
