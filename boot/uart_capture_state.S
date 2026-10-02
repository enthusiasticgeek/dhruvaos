/* Generic UART-output capture (task #317 follow-up, "implement it.
 * fix limitation", 2026-10-02) -- fixes docs/DHDL_ROADMAP.md's own
 * long-standing open question ("whether describe fns print directly
 * or return structured data a caller formats") WITHOUT touching any
 * of the 10 already-registered describe fns, and without changing
 * boot/dhdl_state.S's own dhdl_call_by_id signature at all.
 *
 * Every print primitive in kernel_main.vani (uart_puts, uart_put_
 * hex32, uart_put_i64, dharafs_print_data, ...) bottoms out at exactly
 * ONE function: uart_putc. Rather than thread an output buffer through
 * every describe fn's own signature (a real, much larger change
 * touching 10 already-shipped, already-tested functions), this adds
 * ONE global capture mode that uart_putc itself checks first: when
 * active, a byte is appended to the registered buffer instead of
 * going anywhere near the real hardware FIFO. Any existing code that
 * already prints via the normal primitives is captured for free, with
 * zero changes to that code -- the same "fix at the single lowest
 * common layer" reasoning uart_putc's own CR-before-LF fix (round
 * 2026-09-16) already used for exactly this function.
 *
 * `uart_capture_buf_ptr_word` stores an arbitrary caller-supplied
 * heap pointer (unlike e.g. `wifi_config_ssid_buf_ptr`, which returns
 * the address of a FIXED array baked into that same file) -- same
 * "store a pointer value, load it back later" shape `wifi_radio_
 * state.S`'s own fn-pointer slots already use, just holding a data
 * pointer instead of a code pointer.
 *
 * Callers MUST wrap capture_begin/the captured call/capture_end in
 * the project's own existing dhruva_prio_lock(0)/_unlock ceiling
 * (same mechanism uart_puts itself already uses for cross-task
 * mutual exclusion, task #185) -- without it, a preempting task's own
 * unrelated uart_puts call could land mid-capture and corrupt the
 * buffer with interleaved foreign bytes. This file has no way to
 * enforce that itself; see kernel_main.vani's own dhdl_call_by_id_
 * captured for the one real caller that does it correctly. */

.section ".bss"
.align 4
.global uart_capture_active
uart_capture_active:
    .word 0
uart_capture_buf_ptr_word:
    .word 0
uart_capture_len:
    .word 0
uart_capture_cap:
    .word 0

.section ".text"

.global uart_capture_set_active
uart_capture_set_active:
    ldr r1, =uart_capture_active
    str r0, [r1]
    bx lr

.global uart_capture_get_active
uart_capture_get_active:
    ldr r0, =uart_capture_active
    ldr r0, [r0]
    bx lr

.global uart_capture_set_buf_ptr
uart_capture_set_buf_ptr:
    ldr r1, =uart_capture_buf_ptr_word
    str r0, [r1]
    bx lr

.global uart_capture_get_buf_ptr
uart_capture_get_buf_ptr:
    ldr r0, =uart_capture_buf_ptr_word
    ldr r0, [r0]
    bx lr

.global uart_capture_set_len
uart_capture_set_len:
    ldr r1, =uart_capture_len
    str r0, [r1]
    bx lr

.global uart_capture_get_len
uart_capture_get_len:
    ldr r0, =uart_capture_len
    ldr r0, [r0]
    bx lr

.global uart_capture_set_cap
uart_capture_set_cap:
    ldr r1, =uart_capture_cap
    str r0, [r1]
    bx lr

.global uart_capture_get_cap
uart_capture_get_cap:
    ldr r0, =uart_capture_cap
    ldr r0, [r0]
    bx lr
