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

/* uart_tx_ring_push_and_drain(c: u32) -> u32 -- r0 = byte to enqueue.
 * Pushes c into the ring (dropped only if the ring itself is full --
 * a 64-byte buffer, not the hardware's own 16-byte one), then attempts
 * to drain exactly one byte from the ring to the real UART TX FIFO if
 * there's room. Return value unused by the caller (matches the
 * existing uart_putc_nonblocking convention); r0 = 0 always.
 *
 * Uses r0-r5 as scratch, all caller-saved under AAPCS -- this
 * function's only caller (uart_putc_nonblocking, via vani's own
 * extern "C" call) never has anything live across the call it needs
 * preserved, same reasoning every other accessor function in this
 * project's boot/*_state.S files already relies on. */
.global uart_tx_ring_push_and_drain
uart_tx_ring_push_and_drain:
    push {r4, r5, lr}
    mov r5, r0                  /* r5 = c, preserved across the whole routine */

    ldr r1, =uart_tx_ring_head
    ldr r2, [r1]                /* r2 = head */
    ldr r3, =uart_tx_ring_tail
    ldr r4, [r3]                /* r4 = tail */
    add r0, r2, #1
    and r0, r0, #63             /* r0 = next_head = (head + 1) & 63 */
    cmp r0, r4
    beq drain_step               /* ring full -- skip the push, still try to drain */

    ldr r1, =uart_tx_ring_buf
    strb r5, [r1, r2]            /* buf[head] = c */
    ldr r1, =uart_tx_ring_head
    str r0, [r1]                 /* head = next_head */

drain_step:
    ldr r1, =uart_tx_ring_head
    ldr r2, [r1]                 /* r2 = head (possibly just updated) */
    ldr r3, =uart_tx_ring_tail
    ldr r4, [r3]                 /* r4 = tail */
    cmp r2, r4
    beq done                     /* ring empty -- nothing to drain */

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

done:
    mov r0, #0
    mov r1, #0
    pop {r4, r5, lr}
    bx lr
