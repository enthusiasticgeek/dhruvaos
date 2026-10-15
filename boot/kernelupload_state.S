/* A/B kernel slots, Phase 4 -- persistent scratch state for the
 * `kernelupload` shell command. Same shape as boot/usb_wifi_state.S's
 * own usb_wifi_fw_buf/_chunk/_upload_len (fixed .bss arrays/words, not
 * heap-allocated -- this state is small and fixed-size, no need for
 * dhruva_alloc_bytes at all).
 *
 * kernelupload_block_buf: one 512-byte SD block's worth of
 * accumulation, filled 48 bytes at a time by `kernelupload chunk`,
 * flushed via sdhost_write_block once full -- kernelupload never
 * holds more than one block of the uploaded image in memory at once,
 * unlike wifikey's own whole-file 16KB buffer (a multi-MB kernel image
 * doesn't fit in this project's 768KB heap, let alone .bss).
 *
 * kernelupload_sha_ctx: a serialized vani-crypto-hash Sha256Ctx
 * (`h: [u32;8], carry: [u8;64], carry_len: i64, total_len: u64` --
 * 32+64+8+8 = 112 bytes), persisted across many `chunk` calls the same
 * way kernel_main.vani's own sha256_hash adapter already walks this
 * same struct within a single call -- here it has to survive BETWEEN
 * calls instead, since the whole image is never in memory at once to
 * hash in one shot.
 *
 * kernelupload_total_len: running byte count received so far this
 * upload session (also the write offset, in bytes, from the target
 * slot's own base block).
 *
 * kernelupload_target_slot: which slot (0=A, 1=B) is being written to
 * -- always the INACTIVE slot, decided once at the first `chunk` of a
 * fresh upload (kernelupload_active transitions 0->1) and held fixed
 * until `commit`/`abort`.
 */
.section ".bss"
.align 4
kernelupload_block_buf:
    .space 512
kernelupload_sha_ctx:
    .space 112
kernelupload_total_len:
    .space 4
kernelupload_target_slot:
    .space 4
kernelupload_active:
    .space 4
/* Decode scratch for one `chunk` call's hex -- same 48-byte cap as
 * wifikey's own chunk size (shell line buffer limit, see
 * shell_dispatch_wifikey's own comment), kept separate from
 * usb_wifi_fw_chunk rather than sharing it, since the two features
 * are conceptually unrelated even though both are only ever driven
 * interactively by the same single task (task_f) and so could
 * technically share safely. */
kernelupload_chunk_decode_buf:
    .space 48
/* Dedicated scratch for reading/writing the 512-byte slot-state
 * record (blocks 9216/9217) -- deliberately separate from
 * kernelupload_block_buf (which only ever holds kernel-PAYLOAD bytes
 * mid-upload) and from dharafs_sd_scratch (DharaFS's own general-
 * purpose raw-block buffer), so kernelslot/kernelupload's own slot-
 * state reads can never clobber either mid-operation. */
kernelslot_record_buf:
    .space 512
/* TASK #355 (2026-10-12): `kernelupload stream <len>` -- raw-binary
 * mode, no hex/no per-line shell round trip. kernelupload_stream_
 * active gates irq_dispatch's own UART-RX branch (kernel_main.vani):
 * while set, it skips the UART_RX_IRQ_BUDGET_PER_TICK sporadic-server
 * check ENTIRELY and drains the FIFO on every IRQ unconditionally --
 * a deliberate, scoped exception to the budget (see that constant's
 * own header comment) for this one, operator-initiated, UART-
 * exclusive bulk-transfer mode. kernelupload_stream_expected_len is
 * the total byte count `stream` was told to expect, so irq_dispatch
 * can detect completion and fall back to normal budgeted shell
 * behavior on its own, with no host-side "stop" message needed.
 * kernelupload_stream_last_ack_len tracks total_len as of the last
 * progress ack sent, so the drain path only needs a cheap `-` and
 * compare (not a division) to decide whether a new 64KB boundary was
 * crossed this call. kernelupload_stream_batch_buf is scratch for one
 * IRQ's worth of raw bytes -- 32 bytes, double the PL011's real
 * 16-byte RX FIFO depth, so a single call's drain (now unbounded by
 * budget, draining until the FIFO reports empty) always has real
 * headroom even if ISR entry latency let a couple of extra bytes
 * arrive beyond one full FIFO's worth before this ran. */
kernelupload_stream_active:
    .space 4
kernelupload_stream_expected_len:
    .space 4
kernelupload_stream_last_ack_len:
    .space 4
kernelupload_stream_batch_buf:
    .space 32
/* TASK #355, round 2: kernelupload_rx_ring is a lock-free single-
 * producer/single-consumer byte ring -- irq_dispatch (interrupt
 * context) is its ONLY producer, task_f (its own new streaming
 * branch) is its ONLY consumer. An SPSC ring like this needs NO
 * cpsid/cpsie masking on either side, unlike uart_tx_ring (boot/
 * uart_tx_ring_state.S, genuinely multi-producer) -- head is written
 * only by the producer, tail only by the consumer, and a plain
 * aligned 32-bit load/store is already atomic on this single-core
 * target, the only property an SPSC ring actually needs for
 * correctness. This exists because the FIRST version of `kernelupload
 * stream` called kernelupload_accumulate_bytes (which flushes to SD
 * via sdhost_write_block) directly from irq_dispatch -- a real build
 * failure (irq_dispatch's own #[bounded_stack(bytes=1024)]/#[wcet(...)]
 * budgets, blown by the SD/driver call chain this pulled in) that
 * confirmed what every other SD-touching path in this codebase already
 * assumes: SD access never belongs in interrupt context. This ring is
 * the fix -- irq_dispatch only ever copies raw bytes in (O(1), no SD,
 * no sha256), task_f drains it and does the real work entirely at task
 * level, busy-polling (no sleep) while a stream is active.
 *
 * 4096 bytes, a power of two (wraparound is `& 4095`, matching uart_
 * tx_ring's own `& 63` reasoning) -- generous margin (≈355ms of
 * continuous full-rate 115200-baud arrival) against task_f being
 * delayed re-entering its own drain loop by higher-priority
 * preemption, not a size tuned against any measured real-HW number
 * yet (real-HW retest pending, same as the rest of this task). */
kernelupload_rx_ring_buf:
    .space 4096
kernelupload_rx_ring_head:
    .space 4
kernelupload_rx_ring_tail:
    .space 4
/* TASK #355 follow-up (real-HW find, 2026-10-15): a stream has no
 * host-initiated abort path once started -- confirmed live, the hard
 * way. A real upload attempt got killed by its own outer timeout
 * while a large os.write() was still blocked mid-drain (the real
 * serial throughput hadn't finished feeding the OS's own TTY buffer
 * yet); the board was left with kernelupload_stream_active==1,
 * correctly waiting forever for bytes that could now never arrive,
 * since the dead connection meant no new shell commands could reach
 * it either (incoming bytes are stream payload while this flag is
 * set, by design -- that's the whole point). Recovered by hand that
 * time (sent enough throwaway padding bytes to force total_len up to
 * the stream's own declared length, triggering DONE) -- not a fix,
 * just a workaround available this once because the exact expected
 * length was known. kernelupload_stream_last_activity_tick is the
 * real fix: task_f's own streaming branch stamps this every time it
 * actually pops new bytes from the ring, and auto-aborts the stream
 * (falls back to normal shell processing on its own, no host action
 * needed) if too many ticks pass with zero new bytes -- see task_f's
 * own comment for the exact bound and reasoning. */
kernelupload_stream_last_activity_tick:
    .space 4

.section ".text"

.global kernelupload_block_buf_get
kernelupload_block_buf_get:
    ldr r0, =kernelupload_block_buf
    mov r1, #0
    bx lr

.global kernelupload_sha_ctx_get
kernelupload_sha_ctx_get:
    ldr r0, =kernelupload_sha_ctx
    mov r1, #0
    bx lr

.global kernelupload_total_len_get
kernelupload_total_len_get:
    ldr r0, =kernelupload_total_len
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_total_len_set
kernelupload_total_len_set:
    ldr r1, =kernelupload_total_len
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_target_slot_get
kernelupload_target_slot_get:
    ldr r0, =kernelupload_target_slot
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_target_slot_set
kernelupload_target_slot_set:
    ldr r1, =kernelupload_target_slot
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_active_get
kernelupload_active_get:
    ldr r0, =kernelupload_active
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_active_set
kernelupload_active_set:
    ldr r1, =kernelupload_active
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_chunk_decode_buf_get
kernelupload_chunk_decode_buf_get:
    ldr r0, =kernelupload_chunk_decode_buf
    mov r1, #0
    bx lr

.global kernelslot_record_buf_get
kernelslot_record_buf_get:
    ldr r0, =kernelslot_record_buf
    mov r1, #0
    bx lr

.global kernelupload_stream_active_get
kernelupload_stream_active_get:
    ldr r0, =kernelupload_stream_active
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_stream_active_set
kernelupload_stream_active_set:
    ldr r1, =kernelupload_stream_active
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_stream_expected_len_get
kernelupload_stream_expected_len_get:
    ldr r0, =kernelupload_stream_expected_len
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_stream_expected_len_set
kernelupload_stream_expected_len_set:
    ldr r1, =kernelupload_stream_expected_len
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_stream_last_ack_len_get
kernelupload_stream_last_ack_len_get:
    ldr r0, =kernelupload_stream_last_ack_len
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_stream_last_ack_len_set
kernelupload_stream_last_ack_len_set:
    ldr r1, =kernelupload_stream_last_ack_len
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_stream_batch_buf_get
kernelupload_stream_batch_buf_get:
    ldr r0, =kernelupload_stream_batch_buf
    mov r1, #0
    bx lr

.global kernelupload_rx_ring_buf_get
kernelupload_rx_ring_buf_get:
    ldr r0, =kernelupload_rx_ring_buf
    mov r1, #0
    bx lr

.global kernelupload_rx_ring_head_get
kernelupload_rx_ring_head_get:
    ldr r0, =kernelupload_rx_ring_head
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_rx_ring_head_set
kernelupload_rx_ring_head_set:
    ldr r1, =kernelupload_rx_ring_head
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_rx_ring_tail_get
kernelupload_rx_ring_tail_get:
    ldr r0, =kernelupload_rx_ring_tail
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_rx_ring_tail_set
kernelupload_rx_ring_tail_set:
    ldr r1, =kernelupload_rx_ring_tail
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_stream_last_activity_tick_get
kernelupload_stream_last_activity_tick_get:
    ldr r0, =kernelupload_stream_last_activity_tick
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_stream_last_activity_tick_set
kernelupload_stream_last_activity_tick_set:
    ldr r1, =kernelupload_stream_last_activity_tick
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
