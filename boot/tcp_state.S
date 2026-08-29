/* Dhruva Phase 6 -- TCP connection persistent state (ARM32).
 *
 * Same shape of problem as every other .bss-plus-accessor file in
 * this project: TCP is inherently stateful (sequence/ack numbers,
 * connection state) across many separate calls, with no top-level
 * vani global to hold it. Two connection slots, not one -- unlike
 * netif/ARP's single-implicit-endpoint precedent, demonstrating a
 * real TCP handshake/data-transfer/close cycle over loopback needs
 * BOTH sides' state tracked independently and simultaneously (an
 * "active open" client role in slot 0, a "passive open" server role
 * in slot 1), since this is a single-threaded environment with no
 * second task available to run the other side concurrently -- the
 * self-test itself plays traffic-cop, manually handing each side's
 * outgoing segment to the other side's handle_segment call. See
 * kernel_main.vani's tcp_conn_* functions for the actual state
 * machine logic; this file is purely the persistent storage.
 *
 * Every field is deliberately `u32` (never `i64`), matching
 * arp_state.S's own defensive convention against the exact AAPCS
 * register-pairing bug netif_state.S's netif_set_slot_len hit (see
 * that file's own comment): a u32 is a genuine single AAPCS register
 * regardless of how many other u32 parameters precede it in the same
 * call, so this bug class can't reoccur here by construction. */

.section ".bss"
.align 4
tcp_conn_state:
    .word 0, 0           /* 0=CLOSED 1=SYN_SENT 2=SYN_RCVD 3=ESTABLISHED
                          * 4=FIN_WAIT 5=CLOSED (post-close, distinct
                          * from initial CLOSED only for clarity in
                          * self-test assertions) */
tcp_conn_local_seq:
    .word 0, 0            /* next byte WE will send on this connection */
tcp_conn_remote_seq:
    .word 0, 0            /* next byte WE expect FROM the remote peer */
tcp_conn_local_port:
    .word 0, 0
tcp_conn_remote_port:
    .word 0, 0
tcp_conn_local_ip:
    .word 0, 0
tcp_conn_remote_ip:
    .word 0, 0
tcp_conn_rtx_deadline:
    .word 0, 0           /* Round 37: tick count after which a pending
                          * SYN or data segment should be retransmitted;
                          * 0 = nothing pending. Checked on every
                          * tcp_conn_poll call, not just when a frame
                          * actually arrives -- a lost segment produces
                          * no frame at all, so this is the only thing
                          * that can ever notice. */
tcp_conn_rtx_count:
    .word 0, 0           /* retries attempted for the CURRENT pending
                          * segment; give up (see tcp_rtx_max_retries)
                          * rather than retrying forever */
tcp_conn_rtx_seq:
    .word 0, 0           /* the seq number the pending segment was
                          * originally sent at -- for a SYN (rtx_len=0)
                          * this is the connection's own initial_seq;
                          * for data this is local_seq as it was BEFORE
                          * tcp_conn_send_data advanced it, needed to
                          * detect whether a later ACK has already
                          * covered this exact segment */
tcp_conn_rtx_len:
    .word 0, 0           /* 0 = the pending retransmission is a bare
                          * SYN (no payload); > 0 = a data segment,
                          * this many bytes of tcp_conn_rtx_buf */

.section ".bss"
.align 4
tcp_conn_rtx_buf:
    .space 128            /* 2 x 64 bytes -- one retransmit buffer per
                          * connection slot, sized to match every other
                          * small-payload convention already used
                          * throughout this project's networking layer
                          * (BOT's CBW, UDP self-test payloads, this
                          * project's own 64-byte shell text cap) */

.section ".text"

/* u32 tcp_conn_get_state(u32 conn_id) */
.global tcp_conn_get_state
tcp_conn_get_state:
    ldr r1, =tcp_conn_state
    ldr r0, [r1, r0, lsl #2]
    bx lr

/* u32 tcp_conn_set_state(u32 conn_id, u32 value) */
.global tcp_conn_set_state
tcp_conn_set_state:
    ldr r2, =tcp_conn_state
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_local_seq
tcp_conn_get_local_seq:
    ldr r1, =tcp_conn_local_seq
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_local_seq
tcp_conn_set_local_seq:
    ldr r2, =tcp_conn_local_seq
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_remote_seq
tcp_conn_get_remote_seq:
    ldr r1, =tcp_conn_remote_seq
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_remote_seq
tcp_conn_set_remote_seq:
    ldr r2, =tcp_conn_remote_seq
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_local_port
tcp_conn_get_local_port:
    ldr r1, =tcp_conn_local_port
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_local_port
tcp_conn_set_local_port:
    ldr r2, =tcp_conn_local_port
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_remote_port
tcp_conn_get_remote_port:
    ldr r1, =tcp_conn_remote_port
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_remote_port
tcp_conn_set_remote_port:
    ldr r2, =tcp_conn_remote_port
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_local_ip
tcp_conn_get_local_ip:
    ldr r1, =tcp_conn_local_ip
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_local_ip
tcp_conn_set_local_ip:
    ldr r2, =tcp_conn_local_ip
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_remote_ip
tcp_conn_get_remote_ip:
    ldr r1, =tcp_conn_remote_ip
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_remote_ip
tcp_conn_set_remote_ip:
    ldr r2, =tcp_conn_remote_ip
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_rtx_deadline
tcp_conn_get_rtx_deadline:
    ldr r1, =tcp_conn_rtx_deadline
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_rtx_deadline
tcp_conn_set_rtx_deadline:
    ldr r2, =tcp_conn_rtx_deadline
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_rtx_count
tcp_conn_get_rtx_count:
    ldr r1, =tcp_conn_rtx_count
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_rtx_count
tcp_conn_set_rtx_count:
    ldr r2, =tcp_conn_rtx_count
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_rtx_seq
tcp_conn_get_rtx_seq:
    ldr r1, =tcp_conn_rtx_seq
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_rtx_seq
tcp_conn_set_rtx_seq:
    ldr r2, =tcp_conn_rtx_seq
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global tcp_conn_get_rtx_len
tcp_conn_get_rtx_len:
    ldr r1, =tcp_conn_rtx_len
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global tcp_conn_set_rtx_len
tcp_conn_set_rtx_len:
    ldr r2, =tcp_conn_rtx_len
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

/* mut ref i64 tcp_conn_get_rtx_buf(u32 conn_id) -- returns the address
 * of this connection's own 64-byte slice of tcp_conn_rtx_buf, NOT a
 * word value, so r1 (the return's high word, per this project's own
 * i64-return convention -- see round 30's dhruva_heap_used_bytes ABI
 * bug for why this actually matters) is explicitly zeroed like every
 * other pointer-returning accessor in this codebase. */
.global tcp_conn_get_rtx_buf
tcp_conn_get_rtx_buf:
    ldr r1, =tcp_conn_rtx_buf
    mov r2, #64
    mla r0, r0, r2, r1
    mov r1, #0
    bx lr
