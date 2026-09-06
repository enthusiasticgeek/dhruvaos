/* Dhruva round 89 -- Phase A step 4 of the networking/SSH/WiFi scope
 * (see project memory project_dhruva_networking_ssh_wifi_scope_
 * 2026_09_06.md): TCP connection persistent state, direct port of
 * kernel_main.vani's own boot/tcp_state.S design -- same 2 fixed
 * connection slots (0=client/active-open, 1=server/passive-open;
 * a single-threaded environment has no second task to run "the other
 * side" concurrently, so the state machine's own self-test plays
 * traffic cop between both slots instead of needing a real second
 * host), same field set, same u32-everywhere discipline (a genuine
 * single AAPCS register regardless of how many other u32 params
 * precede it, avoiding the exact register-pairing bug class
 * netif_state.S's own history already flags).
 *
 * rtx_buf (the pending-retransmission payload, up to 64 bytes/conn)
 * is per-byte accessed, same reasoning as arp_state.S's MAC bytes and
 * netif_state.S's frame bytes: no raw pointer ever crosses the vani/
 * asm boundary on this port.
 *
 * tcp_conn_reset(conn_id) is NEW relative to Pi 1's own file -- Pi 1's
 * kernel_main.vani never needed one (its self-tests only ever run
 * once per boot); this port's self-tests are also rerunnable on
 * demand via the `tcp` shell command, so a clean-slate reset matters
 * here the way arp_cache_reset/netif_state_reset already do for their
 * own modules.
 *
 * AAPCS64 note (see [[feedback_aapcs_callee_saved_registers_asm]]):
 * every function below only uses x0-x15 as scratch and never calls
 * another function internally. */
.section ".bss"
.align 4
tcp_conn_state:         .space 8   /* 2 slots * 4 bytes/u32 */
.align 4
tcp_conn_local_seq:     .space 8
.align 4
tcp_conn_remote_seq:    .space 8
.align 4
tcp_conn_local_port:    .space 8
.align 4
tcp_conn_remote_port:   .space 8
.align 4
tcp_conn_local_ip:      .space 8
.align 4
tcp_conn_remote_ip:     .space 8
.align 4
tcp_conn_rtx_deadline:  .space 8
.align 4
tcp_conn_rtx_count:     .space 8
.align 4
tcp_conn_rtx_seq:       .space 8
.align 4
tcp_conn_rtx_len:       .space 8
.align 4
tcp_conn_remote_window: .space 8
.align 4
tcp_conn_rtx_buf:       .space 128 /* 2 slots * 64 bytes */

.section ".text"

/* u32 tcp_conn_reset(u32 conn_id) -- zeroes every word field for one
 * slot (rtx_buf's own bytes don't need zeroing: rtx_len==0 after this
 * means nothing ever reads them, same convention netif_state_reset
 * already uses for its own queue buffers). */
.global tcp_conn_reset
tcp_conn_reset:
    adrp x1, tcp_conn_state
    add x1, x1, :lo12:tcp_conn_state
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_local_seq
    add x1, x1, :lo12:tcp_conn_local_seq
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_remote_seq
    add x1, x1, :lo12:tcp_conn_remote_seq
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_local_port
    add x1, x1, :lo12:tcp_conn_local_port
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_remote_port
    add x1, x1, :lo12:tcp_conn_remote_port
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_local_ip
    add x1, x1, :lo12:tcp_conn_local_ip
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_remote_ip
    add x1, x1, :lo12:tcp_conn_remote_ip
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_rtx_deadline
    add x1, x1, :lo12:tcp_conn_rtx_deadline
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_rtx_count
    add x1, x1, :lo12:tcp_conn_rtx_count
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_rtx_seq
    add x1, x1, :lo12:tcp_conn_rtx_seq
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_rtx_len
    add x1, x1, :lo12:tcp_conn_rtx_len
    str wzr, [x1, w0, uxtw #2]
    adrp x1, tcp_conn_remote_window
    add x1, x1, :lo12:tcp_conn_remote_window
    str wzr, [x1, w0, uxtw #2]
    mov x0, #0
    ret

.macro TCP_CONN_ACCESSOR name, sym
.global tcp_conn_get_\name
tcp_conn_get_\name:
    adrp x1, \sym
    add x1, x1, :lo12:\sym
    ldr w0, [x1, w0, uxtw #2]
    ret
.global tcp_conn_set_\name
tcp_conn_set_\name:
    adrp x2, \sym
    add x2, x2, :lo12:\sym
    str w1, [x2, w0, uxtw #2]
    mov x0, #0
    ret
.endm

TCP_CONN_ACCESSOR state, tcp_conn_state
TCP_CONN_ACCESSOR local_seq, tcp_conn_local_seq
TCP_CONN_ACCESSOR remote_seq, tcp_conn_remote_seq
TCP_CONN_ACCESSOR local_port, tcp_conn_local_port
TCP_CONN_ACCESSOR remote_port, tcp_conn_remote_port
TCP_CONN_ACCESSOR local_ip, tcp_conn_local_ip
TCP_CONN_ACCESSOR remote_ip, tcp_conn_remote_ip
TCP_CONN_ACCESSOR rtx_deadline, tcp_conn_rtx_deadline
TCP_CONN_ACCESSOR rtx_count, tcp_conn_rtx_count
TCP_CONN_ACCESSOR rtx_seq, tcp_conn_rtx_seq
TCP_CONN_ACCESSOR rtx_len, tcp_conn_rtx_len
TCP_CONN_ACCESSOR remote_window, tcp_conn_remote_window

/* u32 tcp_conn_get_rtx_byte(u32 conn_id, u32 byte_idx) -- slot base
 * is conn_id*64, matching tcp_conn_rtx_buf's own 64-byte-per-entry
 * layout. */
.global tcp_conn_get_rtx_byte
tcp_conn_get_rtx_byte:
    mov w2, #64
    mul w3, w0, w2          /* w3 = conn_id * 64 */
    add w3, w3, w1          /* w3 += byte_idx */
    adrp x4, tcp_conn_rtx_buf
    add x4, x4, :lo12:tcp_conn_rtx_buf
    ldrb w0, [x4, w3, uxtw]
    ret

/* u32 tcp_conn_set_rtx_byte(u32 conn_id, u32 byte_idx, u32 value) */
.global tcp_conn_set_rtx_byte
tcp_conn_set_rtx_byte:
    mov w3, #64
    mul w4, w0, w3          /* w4 = conn_id * 64 */
    add w4, w4, w1          /* w4 += byte_idx */
    adrp x5, tcp_conn_rtx_buf
    add x5, x5, :lo12:tcp_conn_rtx_buf
    strb w2, [x5, w4, uxtw]
    mov x0, #0
    ret
