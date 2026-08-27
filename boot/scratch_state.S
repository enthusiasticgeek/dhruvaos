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
    .word 0             /* 128 bytes: eval_expr_raw's value stack, 16
                         * slots of 8 bytes each (a hi/lo u32 pair per
                         * i64) -- was 64 bytes / 4 bytes-per-slot until
                         * round 2's audit found that storing each value
                         * as a single truncating u32 silently corrupted
                         * any number beyond +-2 billion the instant it
                         * was pushed (see eval_write_value/
                         * eval_read_value in kernel_main.vani) */
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
dwc2_dma_scratch_addr:
    .word 0             /* 64 bytes: the DWC2 host channel's DMA
                         * buffer for control transfers (SETUP packet,
                         * descriptor data). This model is DMA-only
                         * (FIFO/slave-mode MMIO is unimplemented, see
                         * kernel_main.vani's dwc2 section header
                         * comment) -- HCDMA(n) must point at a real
                         * buffer, and the same "never call
                         * dhruva_alloc_bytes on every call" lesson
                         * from the FS/shell bug applies here too, since
                         * enumeration issues many transfers over one
                         * session. Not shared with the FS-layer
                         * scratch buffers above -- USB has no
                         * established call-graph relationship to those
                         * yet, so it gets its own dedicated buffer
                         * rather than assuming sharing is safe without
                         * verifying it the way those were. */
tcp_empty_payload_scratch_addr:
    .word 0             /* 1 byte: the placeholder payload pointer
                         * every TCP control segment (SYN, ACK, FIN,
                         * ...) passes to tcp_send_segment with
                         * payload_len=0 -- its CONTENT is never read
                         * or written (tcp_build_header's own payload
                         * copy loop never executes when payload_len is
                         * 0), only a valid non-null pointer is needed.
                         * Found via the exact same audit as every
                         * other entry in this file: tcp_conn_handle_
                         * segment allocated a fresh one of these on
                         * every one of its five response branches, and
                         * it's called once per INCOMING SEGMENT --
                         * potentially many times over one real TCP
                         * connection's lifetime, the identical "called
                         * repeatedly at runtime, not just once at
                         * boot" shape as the FS-layer bug this file
                         * was created to fix. */
net_send_scratch_addr:
    .word 0             /* 512 bytes: the one Ethernet+IP(+UDP/TCP)
                         * frame buffer ipv4_send/udp_send/
                         * tcp_send_segment each build their outgoing
                         * frame into. Found via the SAME audit as
                         * tcp_empty_payload_scratch above, and just as
                         * serious: these three ARE this whole
                         * project's real network send path, each
                         * originally allocating its own fresh 512-byte
                         * buffer on every single call -- undetected so
                         * far only because nothing has driven them in
                         * a real loop yet (self-tests call each a
                         * handful of times), but tcp_send_segment
                         * alone is reachable from tcp_conn_handle_
                         * segment (once per incoming TCP segment) as
                         * well as every tcp_conn_* API function, so
                         * any real, sustained use of this networking
                         * stack -- exactly what it exists for -- would
                         * have exhausted the 64KB heap in well under
                         * 150 sends. Safe to share one instance
                         * across all three: none of them call each
                         * other (each independently builds a complete
                         * frame from scratch, no nesting), so there's
                         * no point where two of them could need this
                         * buffer's contents to coexist.
                         *
                         * NOT YET verified safe against a second
                         * concurrent task using this networking stack
                         * (unlike the FS-layer buffers above, whose
                         * task_e/task_f-only, tied-priority safety
                         * argument was checked call site by call
                         * site) -- nothing calls into networking from
                         * any task today, only single-threaded boot
                         * self-tests. Re-verify this sharing argument
                         * before wiring any task up to send network
                         * traffic. */
net_recv_scratch_addr:
    .word 0             /* 512 bytes: socket_udp_recv's own internal
                         * received-frame buffer -- same bug, same
                         * fix. A future TCP-level socket_tcp_recv
                         * equivalent would need the same treatment;
                         * tcp_conn_handle_segment itself doesn't need
                         * this one since its `frame` is always a
                         * caller-supplied parameter, never its own
                         * internal allocation. */

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

.global dwc2_dma_scratch_set
dwc2_dma_scratch_set:
    ldr r1, =dwc2_dma_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global dwc2_dma_scratch_get
dwc2_dma_scratch_get:
    ldr r0, =dwc2_dma_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global tcp_empty_payload_scratch_set
tcp_empty_payload_scratch_set:
    ldr r1, =tcp_empty_payload_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global tcp_empty_payload_scratch_get
tcp_empty_payload_scratch_get:
    ldr r0, =tcp_empty_payload_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global net_send_scratch_set
net_send_scratch_set:
    ldr r1, =net_send_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global net_send_scratch_get
net_send_scratch_get:
    ldr r0, =net_send_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global net_recv_scratch_set
net_recv_scratch_set:
    ldr r1, =net_recv_scratch_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global net_recv_scratch_get
net_recv_scratch_get:
    ldr r0, =net_recv_scratch_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

/* u32 ptr_to_u32(mut ref i64 p) -- a pointer and a raw address integer
 * are the identical bits in the same register at the AAPCS level;
 * vani's own type system just has no `as` cast between them (a
 * `mut ref i64 as u32` cast is rejected at compile time). Needed for
 * MMIO registers that take a literal DMA buffer address as a plain
 * value (DWC2's HCDMA(n)) rather than a typed pointer parameter some
 * extern "C" accessor stores on the vani side -- nothing to compute,
 * r0 already holds exactly what's wanted on entry. */
.global ptr_to_u32
ptr_to_u32:
    bx lr
