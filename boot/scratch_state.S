/* Dhruva -- shared, persistent scratch buffers for the FS layer, the
 * interactive shell's command dispatch, and the expression evaluator
 * (ARM32).
 *
 * BUG this file exists to fix (found via a real, reproducible
 * crash-and-reboot-then-GC-runaway-loop under Phase 6's checkpoint
 * regression test -- see fs_compact's own doc comment in
 * kernel_main.vani for the first half of this same story): almost
 * every FS primitive (fs_find_latest_block_raw, fs_append_raw,
 * fs_delete_raw, fs_read, fs_read_raw, fs_list, plus the Str-based
 * fs_find_latest_block/fs_append/fs_delete wrappers) called
 * dhruva_alloc_bytes for its own internal scratch buffer on *every
 * call*, not just once. dhruva_alloc_bytes is a bump allocator that
 * never frees (see runtime_stubs.c) -- fine for something called once
 * at boot, but these are the FS layer's actual per-operation
 * workhorses, called every GC wake (task_e, every 20 ticks) and every
 * shell command (task_f). shell_dispatch's own per-command buffers
 * (line_buf, path_buf, out_buf/data_buf, expr_buf/error_buf) and
 * eval_expr_raw's own value/operator stacks had the exact same shape
 * of bug. Fixing fs_compact's own three buffers alone (its own
 * separate, earlier bug) was not enough -- the heap kept draining
 * through all of these until dhruva_alloc_bytes returned null and
 * something wrote straight through it with no null check, corrupting
 * low memory (the vector table lives at address 0) and crashing the
 * whole system a handful of shell commands into any real session.
 *
 * Every buffer below is allocated exactly once, in kernel_main(),
 * before start_multitasking -- the same pattern task_e's own gc_buf/
 * compact_buf/compact_path_buf/compact_data_buf already established.
 * Safe to share a single instance of each across many call sites
 * because (a) task_e and task_f are the only two tasks that ever touch
 * any of them, both at the same priority, and the scheduler's own
 * "ties favor the incumbent" rule (context_switch.S) means one can
 * never preempt the other mid-operation without an explicit sleep in
 * between -- and neither the FS layer nor shell_dispatch nor
 * eval_expr_raw ever sleeps mid-call; and (b) within any single call
 * chain, whichever function still needs a buffer's contents always
 * finishes reading them before any nested call that reuses the same
 * buffer for something else runs (verified call site by call site,
 * not assumed) -- exactly the same reasoning fs_list's own pre-
 * existing comment about buf/path_buf already relied on for its two
 * allocations, just carried through consistently instead of paired
 * with a fresh allocation every time. */

.section ".bss"
.align 4
fs_sd_scratch_addr:
    .word 0             /* 512 bytes: one on-disk block's worth,
                         * shared by every FS primitive that reads or
                         * builds exactly one raw SD block for its own
                         * internal use */
fs_path_scratch_addr:
    .word 0             /* 32 bytes: one path's worth */
fs_data_scratch_addr:
    .word 0             /* 464 bytes: one record's data payload, or
                         * (shared, never at the same time) one eval
                         * expression's source text */
shell_line_scratch_addr:
    .word 0             /* 128 bytes: shell_dispatch's own copy of the
                         * current input line */
eval_values_scratch_addr:
    .word 0             /* 64 bytes: eval_expr_raw's value stack */
eval_ops_scratch_addr:
    .word 0             /* 64 bytes: eval_expr_raw's operator stack */
uart_digits_scratch_addr:
    .word 0             /* 24 bytes: uart_put_i64's reversed-digit
                         * scratch -- a small, generic print helper
                         * called from many places (including live
                         * eval commands, not just boot self-tests), so
                         * it gets its own dedicated buffer rather than
                         * risking aliasing one already in active use
                         * by whatever called it. */

.section ".text"

.global fs_sd_scratch_set
fs_sd_scratch_set:
    ldr r1, =fs_sd_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global fs_sd_scratch_get
fs_sd_scratch_get:
    ldr r0, =fs_sd_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global fs_path_scratch_set
fs_path_scratch_set:
    ldr r1, =fs_path_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global fs_path_scratch_get
fs_path_scratch_get:
    ldr r0, =fs_path_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global fs_data_scratch_set
fs_data_scratch_set:
    ldr r1, =fs_data_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global fs_data_scratch_get
fs_data_scratch_get:
    ldr r0, =fs_data_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global shell_line_scratch_set
shell_line_scratch_set:
    ldr r1, =shell_line_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global shell_line_scratch_get
shell_line_scratch_get:
    ldr r0, =shell_line_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global eval_values_scratch_set
eval_values_scratch_set:
    ldr r1, =eval_values_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global eval_values_scratch_get
eval_values_scratch_get:
    ldr r0, =eval_values_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global eval_ops_scratch_set
eval_ops_scratch_set:
    ldr r1, =eval_ops_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global eval_ops_scratch_get
eval_ops_scratch_get:
    ldr r0, =eval_ops_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global uart_digits_scratch_set
uart_digits_scratch_set:
    ldr r1, =uart_digits_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global uart_digits_scratch_get
uart_digits_scratch_get:
    ldr r0, =uart_digits_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr
