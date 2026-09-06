/* Dhruva round 84 -- the smallest possible interactive shell on the
 * Pi 4/5 port, mirroring the Pi 1 side's own boot/shell_state.S line
 * buffer (shell_line_buf/shell_line_len/shell_line_ready) exactly in
 * shape, minus that side's su/passwd echo-suppression state
 * (shell_echo_state) -- not needed for a first, minimal command set.
 *
 * shell_rx_push_char is called from kernel_main_rpi4.vani's own
 * rpi4_handle_uart_rx_irq (the same real UART0 RX interrupt round 77
 * already wired up), one byte per received character, exactly the
 * same call site shape Pi 1's own irq_dispatch already uses. Once a
 * full line is ready, boot/rpi4/boot.S's own heartbeat_loop (already
 * calling kernel_main_rpi4.vani's rpi4_heartbeat_tick on every real
 * wfi wakeup since round 79) is the natural, already-proven place to
 * poll for it and dispatch -- deliberately NOT wired into the round
 * 79-83 preemptive-scheduler demo at all, which stays exactly as it
 * was: a bounded, self-terminating proof that disables its own timer
 * and hands control back to boot once it's done. A real, permanent
 * shell facility living in boot's own ordinary control flow needs
 * none of that scheduler machinery to exist at all -- Pi 1's own
 * earliest UART capability similarly predated its scheduler by many
 * rounds. */
.section ".bss"
.align 4
shell_line_buf: .space 128
.align 4
shell_line_len: .word 0
shell_line_ready: .word 0

.section ".text"

/* u32 shell_rx_push_char(u32 c) -- same behavior as Pi 1's own
 * shell_state.S: if a line is already ready (not yet consumed by the
 * dispatcher), drop input. CR/LF marks the line ready. Backspace/DEL
 * decrements the length (floored at 0, no underflow). Otherwise
 * appends the byte if there's room (127 of the 128 bytes -- the last
 * slot deliberately left unused, matching the Pi 1 side). Always
 * returns 0; deliberately branch-simple, callable safely from
 * interrupt context. */
.global shell_rx_push_char
shell_rx_push_char:
    adrp x1, shell_line_ready
    add x1, x1, :lo12:shell_line_ready
    ldr w2, [x1]
    cbnz w2, .Lsrpc_done

    cmp w0, #13
    b.eq .Lsrpc_enter
    cmp w0, #10
    b.eq .Lsrpc_enter
    cmp w0, #8
    b.eq .Lsrpc_backspace
    cmp w0, #127
    b.eq .Lsrpc_backspace

    adrp x3, shell_line_len
    add x3, x3, :lo12:shell_line_len
    ldr w4, [x3]
    cmp w4, #127
    b.ge .Lsrpc_done
    adrp x5, shell_line_buf
    add x5, x5, :lo12:shell_line_buf
    add x5, x5, x4
    strb w0, [x5]
    add w4, w4, #1
    str w4, [x3]
    b .Lsrpc_done

.Lsrpc_enter:
    mov w2, #1
    str w2, [x1]
    b .Lsrpc_done

.Lsrpc_backspace:
    adrp x3, shell_line_len
    add x3, x3, :lo12:shell_line_len
    ldr w4, [x3]
    cbz w4, .Lsrpc_done
    sub w4, w4, #1
    str w4, [x3]

.Lsrpc_done:
    mov x0, #0
    ret

.global shell_get_line_len
shell_get_line_len:
    adrp x0, shell_line_len
    add x0, x0, :lo12:shell_line_len
    ldr w0, [x0]
    ret

.global shell_get_line_ready
shell_get_line_ready:
    adrp x0, shell_line_ready
    add x0, x0, :lo12:shell_line_ready
    ldr w0, [x0]
    ret

/* u32 shell_get_line_byte(u32 offset) -- `uxtw` explicitly
 * zero-extends the caller-passed 32-bit offset before using it as a
 * 64-bit address index; AAPCS64 only guarantees the LOW 32 bits of a
 * u32 argument are meaningful, not that the callER zero-extended the
 * upper half of the register it arrived in. */
.global shell_get_line_byte
shell_get_line_byte:
    adrp x1, shell_line_buf
    add x1, x1, :lo12:shell_line_buf
    ldrb w2, [x1, w0, uxtw]
    mov w0, w2
    ret

.global shell_clear_line
shell_clear_line:
    adrp x0, shell_line_len
    add x0, x0, :lo12:shell_line_len
    str wzr, [x0]
    adrp x1, shell_line_ready
    add x1, x1, :lo12:shell_line_ready
    str wzr, [x1]
    mov x0, #0
    ret
