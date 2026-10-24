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
 * compare (not a division) to decide whether a new ACK boundary was
 * crossed this call (2026-10-23: that boundary is now 512 bytes --
 * KERNELUPLOAD_ACK_INTERVAL_BYTES, kernel_main.vani -- not 64KB, to
 * double as the real ACK-driven flow-control signal test/kernel_
 * upload.py's send_raw_ack_paced blocks on; see this file's own
 * header for the real-HW motivation). kernelupload_stream_batch_buf
 * was 32 bytes ("one IRQ's worth of raw bytes, double the PL011's
 * real 16-byte RX FIFO depth") under the OLD unpaced design, where
 * the host just blasted the whole payload continuously and task_f's
 * own pop-batch size was invisible to the host's timing. 2026-10-23
 * real-HW find (aged-SD-card ACK-driven-flow-control investigation):
 * grown to 512 (one full SD block/ACK window) -- the OLD 32-byte cap
 * forced task_f's own `while true` loop to pop+lock+accumulate+unlock
 * in SIXTEEN separate passes (512/32) to process ONE window, each
 * unlock() a real point where a same-priority peer (task_e/task_fsq)
 * could get scheduled in instead of task_f's own very next pop --
 * live-confirmed (FIQWD STALL firing almost every single ACK-paced
 * window, each one costing close to a full 500ms scheduler tick
 * instead of the expected sub-millisecond SD-write time) once the
 * host started waiting tightly per-window instead of blasting
 * continuously. Same lesson Linux's own tty_buffer/ldisc receive_buf
 * path encodes: drain the WHOLE accumulated buffer in one upcall,
 * not an arbitrary small fixed batch -- the old 32-byte constant was
 * never wrong for the workload it was sized against, just silently
 * wrong for this new one. */
kernelupload_stream_active:
    .space 4
kernelupload_stream_expected_len:
    .space 4
kernelupload_stream_last_ack_len:
    .space 4
kernelupload_stream_batch_buf:
    .space 512
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

/* 2026-10-23 real-HW hang investigation (task #357 follow-up): the
 * last_activity_tick check above is stamped by task_f itself right
 * before it calls into kernelupload_accumulate_bytes -- useless for
 * detecting a hang task_f falls INTO while processing bytes it
 * already popped (confirmed live: a real continuous unpaced 3MB
 * transfer went completely silent after ~131KB, no STALL DIAG ever
 * printed, no SD-wedge-retry checkpoint ever written, then a genuine
 * watchdog-triggered full hard reset -- meaning task_f itself stopped
 * making forward progress and never got back to the top of its own
 * loop to run its own staleness check at all). These three words back
 * an INDEPENDENT stall detector driven from timer_tick_dispatch
 * (FIQ context, runs every tick regardless of task scheduling,
 * confirmed elsewhere in this project to be unstarvable by any
 * task-level hang) that watches kernelupload_total_len_get() for
 * forward progress on its own, with no dependency on task_f ever
 * running again. _last_total_len/_last_tick are the independent
 * snapshot; _stall_reported is a one-shot latch so the diagnostic
 * prints exactly once per stall instead of spamming every tick while
 * still stuck. */
kernelupload_watchdog_last_total_len:
    .space 4
kernelupload_watchdog_last_progress_tick:
    .space 4
kernelupload_watchdog_stall_reported:
    .space 4

/* 2026-10-23 follow-up (user request, generalizing the root-cause fix
 * beyond kernelupload specifically): a protocol-agnostic "maintenance
 * mode" precedence flag ANY bulk UART/USB/WiFi transfer can raise --
 * modeled on the real precedent both Zephyr (k_work deferring
 * long operations out of latency-critical context) and Linux (a
 * scheduling-class/bandwidth-reservation idea, e.g. SCHED_DEADLINE's
 * "this class gets guaranteed precedence") use for exactly this
 * problem: "foreground I/O" gets precedence over "background
 * maintenance" without needing every single background task to know
 * about every single foreground transfer protocol by name. task_e/
 * task_fsq (kernel_main.vani) check this instead of a kernelupload-
 * specific flag; kernelupload AND wifikey's own chunk handlers both
 * engage it now (see their own call sites for the full story).
 *
 * This is the SECONDARY defense, not the primary one -- per Linux/
 * Zephyr's own real precedent (cond_resched()-style bounded critical
 * sections / NAPI-style budgeted polling is the primary defense,
 * since a short critical section can never starve anything for long
 * regardless of what else wants the same lock). task_e's own compact/
 * DHCP-poll critical sections are NOT yet bounded this way -- see
 * docs/TODO.md's own writeup (Phase 2, deliberately scoped OUT of
 * this round) for the real structural fix. This flag exists so an
 * active foreground transfer is never blocked by a background
 * section that is STILL too long despite that -- exactly the
 * "secondary backstop" role priority inheritance plays in both
 * reference OSes, not a substitute for bounding the section itself.
 *
 * _last_touch_tick is a safety net against an ABANDONED transfer
 * (host crashed/disconnected mid-upload, never reached its own
 * commit/abort/DONE path) permanently wedging background maintenance
 * off -- any task reading this flag as active also checks staleness
 * against this tick and may force-clear it if far enough in the past
 * (see maintenance_mode_check_stale's own comment, kernel_main.vani).
 * kernelupload already has its own robust 10s-inactivity auto-abort
 * for its OWN specific flag; this is deliberately a much LONGER,
 * generous bound (independent of that) since it has to cover every
 * current and future protocol that engages it, not just kernelupload's
 * own tuned-for-a-tight-busy-poll-loop timing. */
maintenance_mode_active:
    .space 4
maintenance_mode_last_touch_tick:
    .space 4

/* 2026-10-23 follow-up (investigating a SEPARATE, later-stage stall
 * found after the task_e/task_fsq contention fix above): Phase 1
 * fixed the scheduler-contention stall (task=4/task_e holding
 * ceiling=2), but a continuous unpaced 3MB transfer then hit a
 * DIFFERENT stall ~1.19MB in -- current_task=5 (task_f itself, not
 * blocked), ceiling_depth=0, RX ring genuinely empty, FR=0x91 (RXFE
 * set -- FIFO genuinely empty, NOT the old already-fixed stuck-byte
 * signature which showed RXFE clear), but RIS showed OERIS (bit 10,
 * overrun) latched -- a real overrun happened at SOME point, but
 * tick-granularity (500ms) evidence can't say whether it was
 * recent (immediately preceding the 10s silence) or stale/historical
 * from much earlier in the same transfer. These two words give
 * microsecond-precision, stamped directly from the IRQ handler
 * itself (the only place that ever actually reads a byte off the
 * wire or detects the overrun condition): _last_rx_byte_us is
 * TIMER_CLO at the moment of the most recently successfully-pushed
 * byte during an active kernelupload stream; _overrun_count is a
 * cumulative count of every OERIS-detected event during the stream
 * (previously only cleared, never counted). Printed by the FIQ-level
 * stall detector (kernel_main.vani's own timer_tick_dispatch) so the
 * next real-HW repro can show the EXACT gap since the last real byte
 * arrived, not just "more than 10 ticks' worth of silence." */
kernelupload_last_rx_byte_us:
    .space 4
kernelupload_overrun_count:
    .space 4

/* 2026-10-23 follow-up (user question: "is there an ISR masking issue
 * / timer interrupt?"): two more counters, both reset per-stream, to
 * directly measure the UART IRQ handler's own re-entry rate during an
 * active stream and whether the hardware FIFO is still backlogged
 * after each 32-iteration drain attempt -- rather than continuing to
 * infer this indirectly from overrun_count alone.
 * _uart_irq_entry_count: incremented once per entry into the
 * streaming branch of the UART RX IRQ handler (irq_dispatch,
 * kernel_main.vani), BEFORE the drain loop runs. Comparing this
 * against overrun_count directly answers "does nearly every entry
 * see an overrun" (ratio near 1, pointing at a storm/stuck-flag
 * class of bug) vs "overruns are a small fraction of entries"
 * (pointing at genuine, intermittent real overruns instead).
 * _fifo_backlog_count: incremented once per entry where, AFTER the
 * drain loop's own 32 iterations complete, UART_FR still reports the
 * RX FIFO non-empty -- direct, unambiguous evidence that incoming
 * bytes are arriving faster than this handler's own per-entry drain
 * capacity, independent of anything OERIS-related. */
kernelupload_uart_irq_entry_count:
    .space 4
kernelupload_fifo_backlog_count:
    .space 4

/* 2026-10-23 follow-up (user question: "is ISR or task preempting
 * transfer" -- re-testing the SD-write-masks-IRQ+FIQ-too-long theory
 * with live evidence; an earlier disproof of this exact theory ran
 * BEFORE the ring-reset bug was fixed, so it may itself have been
 * invalid). Worst (max) observed real wall-clock duration of a single
 * sdhost_write_block call during an active stream, reset to 0 at
 * stream start. sdhost_write_block's own masked (IRQ+FIQ disabled)
 * critical section is documented at ~50ms worst case on healthy
 * hardware -- if the real SD card is intermittently much slower
 * (e.g. internal wear-leveling/GC under sustained write load), this
 * directly measures it, in the same units (TIMER_CLO microseconds)
 * as rxdiag's own gap_us, so the two can be compared directly. */
kernelupload_sd_write_worst_us:
    .space 4

/* 2026-10-23 (resumable chunked upload, user request: "keep track
 * successful chunk transfer to know where to resume if stalled at
 * prior attempt... needs attempt limit as well as timeout or board
 * boots last known good slot"). kernelupload_chunk_record_buf is
 * scratch for ONE 512-byte raw block holding a KernelUploadChunk
 * Progress record (built/parsed entirely in vani, kernel_main.vani --
 * same division of labor as kernelslot_record_buf_get/
 * KernelSlotRecord, this file's own existing sibling just below).
 * Persisted to raw SD blocks 9218/9219 (ping-ponged, same power-loss-
 * safety convention as the slot-state record at 9216/9217 -- see
 * kernelslot_state_block_a/_b's own comment, kernel_main.vani, for
 * why ping-pong matters here too: a reboot mid-write to the ACTIVE
 * copy must never leave BOTH copies simultaneously corrupt). Letting
 * a watchdog-triggered reboot mid-upload resume from the next
 * UNCONFIRMED chunk instead of restarting the whole 3MB transfer is
 * the entire point -- this record is what survives the reboot that
 * kernelupload_total_len/kernelupload_ctx (both plain .bss, cleared
 * every boot) never could.
 *
 * kernelupload_chunk_base_block_offset: the ACTIVE chunk's own SD
 * block offset (relative to the target slot's own base block, NOT
 * an absolute block number), set by the `kernelupload chunk` command
 * before streaming starts. kernelupload_accumulate_bytes adds this
 * to its own block_index computation -- 0 for the legacy, non-
 * chunked `kernelupload stream` command (whole-image, starts at the
 * slot's own base block exactly like before this round), nonzero
 * only while a specific chunk (index > 0) is actively streaming. */
kernelupload_chunk_record_buf:
    .space 512
kernelupload_chunk_base_block_offset:
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

.global kernelupload_watchdog_last_total_len_get
kernelupload_watchdog_last_total_len_get:
    ldr r0, =kernelupload_watchdog_last_total_len
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_watchdog_last_total_len_set
kernelupload_watchdog_last_total_len_set:
    ldr r1, =kernelupload_watchdog_last_total_len
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_watchdog_last_progress_tick_get
kernelupload_watchdog_last_progress_tick_get:
    ldr r0, =kernelupload_watchdog_last_progress_tick
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_watchdog_last_progress_tick_set
kernelupload_watchdog_last_progress_tick_set:
    ldr r1, =kernelupload_watchdog_last_progress_tick
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_watchdog_stall_reported_get
kernelupload_watchdog_stall_reported_get:
    ldr r0, =kernelupload_watchdog_stall_reported
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_watchdog_stall_reported_set
kernelupload_watchdog_stall_reported_set:
    ldr r1, =kernelupload_watchdog_stall_reported
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global maintenance_mode_active_get
maintenance_mode_active_get:
    ldr r0, =maintenance_mode_active
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global maintenance_mode_active_set
maintenance_mode_active_set:
    ldr r1, =maintenance_mode_active
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global maintenance_mode_last_touch_tick_get
maintenance_mode_last_touch_tick_get:
    ldr r0, =maintenance_mode_last_touch_tick
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global maintenance_mode_last_touch_tick_set
maintenance_mode_last_touch_tick_set:
    ldr r1, =maintenance_mode_last_touch_tick
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_last_rx_byte_us_get
kernelupload_last_rx_byte_us_get:
    ldr r0, =kernelupload_last_rx_byte_us
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_last_rx_byte_us_set
kernelupload_last_rx_byte_us_set:
    ldr r1, =kernelupload_last_rx_byte_us
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_overrun_count_get
kernelupload_overrun_count_get:
    ldr r0, =kernelupload_overrun_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_overrun_count_incr
kernelupload_overrun_count_incr:
    ldr r0, =kernelupload_overrun_count
    ldr r1, [r0]
    add r1, r1, #1
    str r1, [r0]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_overrun_count_set
kernelupload_overrun_count_set:
    ldr r1, =kernelupload_overrun_count
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_uart_irq_entry_count_get
kernelupload_uart_irq_entry_count_get:
    ldr r0, =kernelupload_uart_irq_entry_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_uart_irq_entry_count_incr
kernelupload_uart_irq_entry_count_incr:
    ldr r0, =kernelupload_uart_irq_entry_count
    ldr r1, [r0]
    add r1, r1, #1
    str r1, [r0]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_uart_irq_entry_count_set
kernelupload_uart_irq_entry_count_set:
    ldr r1, =kernelupload_uart_irq_entry_count
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_fifo_backlog_count_get
kernelupload_fifo_backlog_count_get:
    ldr r0, =kernelupload_fifo_backlog_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_fifo_backlog_count_incr
kernelupload_fifo_backlog_count_incr:
    ldr r0, =kernelupload_fifo_backlog_count
    ldr r1, [r0]
    add r1, r1, #1
    str r1, [r0]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_fifo_backlog_count_set
kernelupload_fifo_backlog_count_set:
    ldr r1, =kernelupload_fifo_backlog_count
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_sd_write_worst_us_get
kernelupload_sd_write_worst_us_get:
    ldr r0, =kernelupload_sd_write_worst_us
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_sd_write_worst_us_set
kernelupload_sd_write_worst_us_set:
    ldr r1, =kernelupload_sd_write_worst_us
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global kernelupload_chunk_record_buf_get
kernelupload_chunk_record_buf_get:
    ldr r0, =kernelupload_chunk_record_buf
    mov r1, #0
    bx lr

.global kernelupload_chunk_base_block_offset_get
kernelupload_chunk_base_block_offset_get:
    ldr r0, =kernelupload_chunk_base_block_offset
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global kernelupload_chunk_base_block_offset_set
kernelupload_chunk_base_block_offset_set:
    ldr r1, =kernelupload_chunk_base_block_offset
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr
