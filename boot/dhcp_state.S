/* Dhruva Phase 6 continued -- DHCP client persistent state (ARM32).
 *
 * Same shape of problem as every other .bss-plus-accessor file in
 * this project: the DHCP client's own state machine (see
 * kernel_main.vani's dhcp_client_start/dhcp_client_poll) needs to
 * survive across many separate calls -- dhcp_client_poll in
 * particular is meant to be called repeatedly (once per received
 * frame, over however many polls it takes a real server to answer),
 * with no top-level vani global to hold the state in between. This
 * file is purely the persistent storage; the actual state-machine
 * logic lives in kernel_main.vani.
 *
 * Every field is deliberately `u32` (never `i64`), matching
 * arp_state.S/tcp_state.S's own defensive convention against the
 * exact AAPCS register-pairing bug netif_state.S's netif_set_slot_len
 * hit (see that file's own comment): a u32 is a genuine single AAPCS
 * register regardless of how many other u32 parameters precede it in
 * the same call, so this bug class can't reoccur here by
 * construction. */

.section ".bss"
.align 4
dhcp_client_state:
    .word 0        /* 0=INIT 1=SELECTING 2=REQUESTING 3=BOUND */
dhcp_xid:
    .word 0        /* transaction ID of the in-flight DISCOVER/REQUEST
                     * -- replies quoting any other xid are ignored */
dhcp_offered_ip:
    .word 0        /* yiaddr from the OFFER, needed again to build the
                     * REQUEST's own Requested-IP option */
dhcp_server_ip:
    .word 0        /* the offering server's own address, from the
                     * OFFER's Server-Identifier option -- echoed back
                     * in the REQUEST's own Server-Identifier option,
                     * per RFC 2131 s4.3.2 */
dhcp_leased_ip:
    .word 0        /* yiaddr from the ACK -- the actual, final bound
                     * address; stored separately from dhcp_offered_ip
                     * rather than assumed identical, since the ACK is
                     * the authoritative source of truth, not the OFFER */

.section ".text"

.global dhcp_state_get_client_state
dhcp_state_get_client_state:
    ldr r0, =dhcp_client_state
    ldr r0, [r0]
    bx lr

.global dhcp_state_set_client_state
dhcp_state_set_client_state:
    ldr r1, =dhcp_client_state
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_state_get_xid
dhcp_state_get_xid:
    ldr r0, =dhcp_xid
    ldr r0, [r0]
    bx lr

.global dhcp_state_set_xid
dhcp_state_set_xid:
    ldr r1, =dhcp_xid
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_state_get_offered_ip
dhcp_state_get_offered_ip:
    ldr r0, =dhcp_offered_ip
    ldr r0, [r0]
    bx lr

.global dhcp_state_set_offered_ip
dhcp_state_set_offered_ip:
    ldr r1, =dhcp_offered_ip
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_state_get_server_ip
dhcp_state_get_server_ip:
    ldr r0, =dhcp_server_ip
    ldr r0, [r0]
    bx lr

.global dhcp_state_set_server_ip
dhcp_state_set_server_ip:
    ldr r1, =dhcp_server_ip
    str r0, [r1]
    mov r0, #0
    bx lr

.global dhcp_state_get_leased_ip
dhcp_state_get_leased_ip:
    ldr r0, =dhcp_leased_ip
    ldr r0, [r0]
    bx lr

.global dhcp_state_set_leased_ip
dhcp_state_set_leased_ip:
    ldr r1, =dhcp_leased_ip
    str r0, [r1]
    mov r0, #0
    bx lr
