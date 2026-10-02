/* Round 2026-09-16: persistent TX ring buffer backing uart_putc_
 * nonblocking (kernel_main.vani). Root cause of a real, previously-
 * undiagnosed bug (docs/TODO.md, "phase4_milestone.py's interactive
 * shell checks flake under load", found round 186 2026-09-12, never
 * investigated until now): uart_putc_nonblocking used to check the
 * PL011's own 16-byte hardware TX FIFO status once and silently DROP
 * the byte if it was full, with no retry -- a deliberate, correct
 * tradeoff for its original callers (the timer-tick '.' dot, the
 * CANARY stack-overflow diagnostic), where an occasional missed debug
 * character is genuinely harmless. shell_echo_char (round 72) reused
 * the SAME function for command-line ECHO, a user-visible correctness
 * path where a silently dropped byte is a real bug, not a cosmetic
 * miss -- confirmed live: docs/TODO.md's own round-186 entry captured
 * "write" echoing back as "rite" (a genuinely dropped leading byte,
 * not a display artifact -- the underlying write still succeeded) and
 * a similarly-timed "eval 6*7" misparsed as "unknown command" despite
 * echoing back intact.
 *
 * Fixed WITHOUT making uart_putc_nonblocking blocking (which would
 * reintroduce exactly the unbounded-wait problem it exists to avoid
 * inside a hard-RT #[wcet(...)] ISR): push into this ring buffer
 * instead of the hardware FIFO directly, and opportunistically drain
 * one byte to real hardware in the same call.
 *
 * FIRST ATTEMPT (vani-level push/drain calling 6 separate extern
 * accessor round-trips between them) blew irq_dispatch's own
 * #[wcet(cycles=130000)] budget to 216690 cycles -- real ARM call/
 * return overhead across that many separate extern fn calls, paid up
 * to 128 times per RX burst (irq_dispatch's own drain loop bound),
 * dominated the actual cost far more than the ring logic itself.
 * Rewritten as ONE combined assembly routine doing the entire push-
 * then-maybe-drain sequence with direct register/memory access and no
 * extern call overhead at all -- the vani side now makes exactly one
 * call per byte, matching (not exceeding) the original design's own
 * call-count shape.
 *
 * 64 bytes -- a power of two on purpose, so wraparound is `& 63`
 * (one AND instruction) rather than a real modulo/division, and 4x
 * the hardware FIFO's own 16-byte depth, generous headroom for one
 * typed line's worth of echo bytes without becoming a large,
 * un-auditable buffer. Classic circular buffer, one slot deliberately
 * left unused so head==tail is unambiguous (empty) without a separate
 * count variable -- 63 usable bytes out of 64 allocated.
 *
 * Persistent scratch allocated once here, not per-call -- this
 * project's own established "never-free heap pattern" (no free()
 * exists on this system; the FS layer's own scratch buffers, HMAC/
 * PBKDF2 state, and every other per-boot-lifetime buffer in this
 * codebase already follow the same discipline). */

.section ".bss"
.align 4
uart_tx_ring_buf:
    .space 64
uart_tx_ring_head:
    .word 0
uart_tx_ring_tail:
    .word 0

.section ".text"

/* 2026-09-26: real-HW UART bit-corruption investigation. This ring's
 * own head/tail read-modify-write below was completely UNMASKED --
 * and this function is called from TWO genuinely different contexts:
 * USR-mode task code (uart_puts_bounded, every ordinary task -- HIGH/
 * MEDIUM/LOW/MUTEX-HIGH/idle/governor) AND directly from real
 * interrupt context (timer_tick_dispatch/spn_shadow_report_mismatch,
 * both running privileged, inside irq_entry.S's own handler, via
 * uart_put_hex32_irq's direct uart_putc_nonblocking calls). On a
 * single ARM1176 core, an interrupt landing mid-update here -- while a
 * task is between reading head/tail and storing the updated value --
 * is a textbook data race: the ISR's own concurrent read-modify-write
 * of the SAME global head/tail (and potentially the same buffer slot)
 * corrupts the ring's internal state and/or its byte contents. This
 * is the root cause found for a real-HW symptom that had, until this
 * round, only been explained by ruling things OUT: a fresh picocom
 * capture showed genuine bit-level corruption -- recognizable text
 * like "idle"/"GOVERNOR" (both printed via this exact path) degrading
 * into repeated garbage, plus picocom's own "M-I" notation for a byte
 * with the high bit incorrectly set -- appearing well into boot and
 * getting worse over time (more interrupts landing in the vulnerable
 * window the longer the system runs), while every OTHER print
 * (uart_puts, writing the hardware FIFO directly with no shared ring
 * state) stayed completely clean. Two other real-HW hypotheses (UART
 * clock desyncing when the CPU governor changes the ARM clock; power-
 * supply undervoltage under load) were tested and DIRECTLY ruled out
 * first -- see project memory for the full round-by-round history.
 *
 * Fixed the same way this project has fixed every other "unmasked
 * shared state, USR-mode callers can't cpsid/cpsie directly" bug
 * before (dhruva_prio_lock/_unlock; the SD driver's own PIO fill/
 * drain loops) -- EXCEPT this is the first case where a caller is
 * ALSO privileged already (real interrupt context), which must never
 * route through the SWI trap: issuing a nested SWI from inside an
 * already-running SVC-mode interrupt handler would clobber lr_svc,
 * corrupting THAT handler's own in-progress return address. This
 * entry point checks its own caller's current mode and picks the
 * correct path itself, so every existing call site (uart_putc_
 * nonblocking, uart_put_hex32_irq) needs zero changes. */
.global uart_tx_ring_push_and_drain
uart_tx_ring_push_and_drain:
    push {r4, lr}
    mrs r4, cpsr
    and r4, r4, #0x1F
    cmp r4, #0x10                /* USR mode (0b10000)? */
    bne utrpd_already_privileged

    /* USR mode -- route through SWI #7 (boot/swi_entry.S) so the
     * masking actually happens in SVC mode, matching this project's
     * established pattern exactly. r0 already holds c; the SWI
     * dispatcher passes r0-r3 through to _impl untouched (r0-r12
     * aren't banked across the trap at all -- see swi_entry.S's own
     * header comment). */
    push {r5, r7}
    mov r5, lr
    mov r7, #7
    swi #0
    mov lr, r5
    pop {r5, r7}
    b utrpd_ret

utrpd_already_privileged:
    /* Already privileged -- this call originated from real interrupt
     * context (timer_tick_dispatch/spn_shadow_report_mismatch, running
     * in SVC/IRQ mode as part of irq_entry.S's own handler, never a
     * USR-mode task). cpsid/cpsie is well-defined and safe here; call
     * the masked implementation directly, no SWI involved. */
    bl uart_tx_ring_push_and_drain_impl

utrpd_ret:
    pop {r4, lr}
    bx lr

/* uart_tx_ring_push_and_drain_impl(c: u32) -> u32 -- the real logic,
 * cpsid/cpsie masking the entire head/tail read-modify-write and FIFO
 * drain. Reachable two ways: directly (bl) from the trampoline above
 * when already privileged, or via SWI #7 when the original caller was
 * in USR mode. r0 = byte to enqueue on entry. Pushes c into the ring
 * (dropped only if the ring itself is full -- a 64-byte buffer, not
 * the hardware's own 16-byte one), then drains up to 16 bytes (the
 * real PL011 TX FIFO depth, not an arbitrary number) from the ring to
 * hardware in the same call, as long as there's room. Return value
 * unused by any caller; r0 = 0 always.
 *
 * 2026-10-01 (real-HW UART corruption investigation, ruler diagnostic
 * round): previously drained exactly ONE byte per call, no matter how
 * much room the hardware FIFO actually had. That one-byte-per-call
 * rate is the real bottleneck, not UART baud rate: timer_tick_dispatch
 * calls uart_putc_nonblocking once per tick (its own '.' heartbeat),
 * and that was the ONLY thing ever draining this ring when nothing
 * else happened to be printing -- confirmed by grep: this is the
 * single call site into the drain logic anywhere in the codebase, no
 * periodic/idle-time flush exists separately. A task that bursts two
 * back-to-back prints (e.g. task_custom_demo's RULER + CUSTOM lines,
 * ~86 bytes together) fills far more of the 64-byte ring than one
 * byte/tick can ever drain before the NEXT burst adds another ~86 --
 * net backlog only grows. Once the ring saturates, old undrained bytes
 * from an unrelated, much earlier print (observed: stray hex digits
 * left over from the capped SLEEP:/FIQ: resume diagnostics, long after
 * those diagnostics' own 8-fire cap had been exhausted) get spliced in
 * front of whatever prints next, byte-correct but visually meaningless
 * -- explaining a real-HW-only, highly consistent early cutoff with no
 * actual bit-level corruption involved: the ruler diagnostic's own
 * exact 36-char string is intact and complete in .rodata (confirmed
 * via `strings` on the built ELF); what gets corrupted is purely the
 * TRANSMISSION ORDER, not the data. QEMU's emulated PL011 apparently
 * never gets backed up the same way (its own stdio chardev likely
 * accepts bytes far faster than one-per-call ever becomes a real
 * bottleneck), which is why this was never reproducible there. */
.global uart_tx_ring_push_and_drain_impl
uart_tx_ring_push_and_drain_impl:
    push {r4, r5, r6, r7, lr}
    mrs r6, cpsr
    cpsid if
    mov r5, r0                  /* r5 = c, preserved across the whole routine */

    ldr r1, =uart_tx_ring_head
    ldr r2, [r1]                /* r2 = head */
    ldr r3, =uart_tx_ring_tail
    ldr r4, [r3]                /* r4 = tail */
    add r0, r2, #1
    and r0, r0, #63             /* r0 = next_head = (head + 1) & 63 */
    cmp r0, r4
    beq drain_loop_init          /* ring full -- skip the push, still try to drain */

    ldr r1, =uart_tx_ring_buf
    strb r5, [r1, r2]            /* buf[head] = c */
    ldr r1, =uart_tx_ring_head
    str r0, [r1]                 /* head = next_head */

drain_loop_init:
    mov r7, #16                  /* bounded burst-drain cap, matching the
                                   * real PL011 TX FIFO depth -- see this
                                   * function's own header comment */
drain_step:
    cmp r7, #0
    beq done                     /* burst cap reached -- remaining backlog
                                   * waits for the next call, same as before */
    sub r7, r7, #1

    ldr r1, =uart_tx_ring_head
    ldr r2, [r1]                 /* r2 = head (possibly just updated) */
    ldr r3, =uart_tx_ring_tail
    ldr r4, [r3]                 /* r4 = tail */
    cmp r2, r4
    beq done                     /* ring empty -- nothing left to drain */

    ldr r1, =0x20201018          /* UART_FR */
    ldr r0, [r1]
    tst r0, #0x20                /* TX FIFO full? (bit 5) */
    bne done                     /* still full -- try again next call */

    ldr r1, =uart_tx_ring_buf
    ldrb r0, [r1, r4]            /* r0 = buf[tail] */
    ldr r1, =0x20201000          /* UART_DR */
    strb r0, [r1]
    add r4, r4, #1
    and r4, r4, #63              /* next_tail = (tail + 1) & 63 */
    ldr r1, =uart_tx_ring_tail
    str r4, [r1]
    b drain_step

done:
    msr cpsr_c, r6
    mov r0, #0
    mov r1, #0
    pop {r4, r5, r6, r7, lr}
    bx lr

/* void uart_tx_ring_drain_only(void) -- pumps the drain side of this
 * ring with NO push, for exactly one caller: timer_tick_dispatch,
 * unconditionally, every tick (2026-10-02, task #319 regression fix).
 *
 * Task #319 ("boot-debug flag: gate tick dot + DIAG prints") gated the
 * tick-dot's OWN uart_putc_nonblocking(46) call behind boot_debug_
 * enabled() -- which defaults OFF. This function's own header comment
 * (above) already documented that the tick-dot was "the ONLY thing
 * ever draining this ring when nothing else happened to be printing"
 * -- gating it silently removed the ring's only idle-time drain pump
 * too, not just its visible character. Real-HW symptom this caused:
 * once the ring backs up even slightly (e.g. a burst of echo bytes
 * with no further prints immediately after), the backlog NEVER drains
 * until something else happens to call uart_putc_nonblocking again --
 * and because this is a FIFO ring, that next caller's own fresh bytes
 * queue up BEHIND the old stale backlog, which drains out FIRST,
 * splicing old leftover bytes in front of new output. Reproduced live
 * this round: shell commands sent well after a prior session's own
 * unrelated prints came back corrupted/truncated, with fragments of
 * long-prior unrelated text (e.g. a stale "ethernet" tail) resurfacing
 * in the middle of a totally different, later command's echo.
 *
 * Fix restores the pump WITHOUT restoring the visible dot: this is
 * drain-ONLY (no push, so nothing new ever gets enqueued by a tick
 * that has nothing to say), called unconditionally regardless of
 * boot_debug_enabled(), while uart_putc_nonblocking(46)'s own push+
 * drain call just above stays gated exactly as task #319 intended --
 * whether the dot is VISIBLE and whether the ring gets PUMPED are two
 * independent concerns that task #319 wrongly conflated by sharing one
 * gated call site for both.
 *
 * Always called from already-privileged interrupt context (timer_
 * tick_dispatch, inside irq_entry.S's own FIQ path) -- no USR-mode
 * caller exists or is expected, so this skips uart_tx_ring_push_and_
 * drain's own mode-check/SWI-routing trampoline entirely and masks/
 * drains directly, matching uart_tx_ring_push_and_drain_impl's own
 * "already privileged" direct-call path.
 *
 * Self-contained copy of the drain loop above (not a branch into
 * drain_loop_init/drain_step/done) -- asm_safety_audit.py's own push/
 * pop balance check works per-function and can't see a pop reached
 * only via fall-through from a different function's labels, so
 * branching in there would be a real audit-tool blind spot even
 * though it is runtime-correct. Duplicating these ~15 lines keeps
 * this function statically auditable on its own, matching this
 * project's own standing preference for auditability over cleverness
 * in safety-critical bare-metal code. */
.global uart_tx_ring_drain_only
uart_tx_ring_drain_only:
    push {r4, r5, r6, r7, lr}
    mrs r6, cpsr
    cpsid if

    mov r7, #16                  /* bounded burst-drain cap, matching the
                                   * real PL011 TX FIFO depth -- see this
                                   * file's own header comment */
drain_only_step:
    cmp r7, #0
    beq drain_only_done           /* burst cap reached -- remaining backlog
                                    * waits for the next tick, same as above */
    sub r7, r7, #1

    ldr r1, =uart_tx_ring_head
    ldr r2, [r1]
    ldr r3, =uart_tx_ring_tail
    ldr r4, [r3]
    cmp r2, r4
    beq drain_only_done           /* ring empty -- nothing left to drain */

    ldr r1, =0x20201018          /* UART_FR */
    ldr r0, [r1]
    tst r0, #0x20                /* TX FIFO full? (bit 5) */
    bne drain_only_done           /* still full -- try again next tick */

    ldr r1, =uart_tx_ring_buf
    ldrb r0, [r1, r4]            /* r0 = buf[tail] */
    ldr r1, =0x20201000          /* UART_DR */
    strb r0, [r1]
    add r4, r4, #1
    and r4, r4, #63              /* next_tail = (tail + 1) & 63 */
    ldr r1, =uart_tx_ring_tail
    str r4, [r1]
    b drain_only_step

drain_only_done:
    msr cpsr_c, r6
    mov r0, #0
    mov r1, #0
    pop {r4, r5, r6, r7, lr}
    bx lr
