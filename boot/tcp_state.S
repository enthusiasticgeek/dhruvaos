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
