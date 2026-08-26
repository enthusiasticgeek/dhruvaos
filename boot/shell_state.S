/* Dhruva Phase 4 -- interactive shell line buffer (ARM32).
 *
 * Same shape of problem every other .bss-plus-extern-accessor file in
 * this project solves: vani has no top-level global variables, but
 * irq_dispatch's UART-RX branch (running once per received byte, in
 * real IRQ context) needs somewhere persistent to build up a typed
 * line across many separate interrupts, and the shell's own command
 * loop (a normal vani task) needs to read it back out once a line is
 * complete.
 *
 * All logic here is intentionally tiny and branch-simple: this runs
 * inside irq_dispatch, a #[interrupt]-tagged function, so it has to
 * stay something a WCET/no-heap-checked ISR can actually call. */

.section ".bss"
.align 4
shell_line_buf:
    .space 128      /* raw bytes of the line currently being typed */
shell_line_len:
    .word 0
shell_line_ready:
    .word 0         /* 0 = still being typed; 1 = Enter was pressed,
                     * a complete line is waiting for the shell loop
                     * to consume it. New input is dropped (not
                     * buffered) while this is 1, rather than risk
                     * corrupting a line the shell hasn't read yet. */

.section ".text"

/* u32 shell_rx_push_char(u32 c) -- called once per byte drained from
 * the UART RX FIFO. Handles CR/LF (marks the line ready), backspace/
 * DEL (shrinks the line), otherwise appends if there's room. */
.global shell_rx_push_char
shell_rx_push_char:
    ldr r1, =shell_line_ready
    ldr r2, [r1]
    cmp r2, #0
    bne shell_rx_done

    cmp r0, #13                 /* CR */
    beq shell_rx_newline
    cmp r0, #10                 /* LF */
    beq shell_rx_newline
    cmp r0, #8                  /* backspace */
    beq shell_rx_backspace
    cmp r0, #127                /* DEL */
    beq shell_rx_backspace

    ldr r1, =shell_line_len
    ldr r2, [r1]
    cmp r2, #127                /* buffer is 128 bytes; leave the last
                                 * slot alone rather than exactly fill it */
    bge shell_rx_done
    ldr r3, =shell_line_buf
    strb r0, [r3, r2]
    add r2, r2, #1
    str r2, [r1]
    b shell_rx_done

shell_rx_backspace:
    ldr r1, =shell_line_len
    ldr r2, [r1]
    cmp r2, #0
    beq shell_rx_done
    sub r2, r2, #1
    str r2, [r1]
    b shell_rx_done

shell_rx_newline:
    ldr r1, =shell_line_ready
    mov r2, #1
    str r2, [r1]

shell_rx_done:
    mov r0, #0
    bx lr

.global shell_get_line_len
shell_get_line_len:
    ldr r0, =shell_line_len
    ldr r0, [r0]
    bx lr

.global shell_get_line_ready
shell_get_line_ready:
    ldr r0, =shell_line_ready
    ldr r0, [r0]
    bx lr

/* u32 shell_get_line_byte(u32 offset) */
.global shell_get_line_byte
shell_get_line_byte:
    ldr r1, =shell_line_buf
    ldrb r0, [r1, r0]
    bx lr

/* u32 shell_clear_line() -- call once the shell loop has finished
 * reading a completed line, to accept new input again. */
.global shell_clear_line
shell_clear_line:
    ldr r1, =shell_line_len
    mov r2, #0
    str r2, [r1]
    ldr r1, =shell_line_ready
    str r2, [r1]
    mov r0, #0
    bx lr
