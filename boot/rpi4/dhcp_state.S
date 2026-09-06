/* Dhruva round 91 -- DHCP client persistent state, direct port of
 * kernel_main.vani's own DHCP client state fields (this port skips
 * that side's separate dhcp_payload_scratch/dhcp_bcast_mac_scratch/
 * dhcp_server_mac_scratch/dhcp_frame_scratch heap buffers entirely --
 * this port has no heap, so every round so far builds its own local
 * `[u8; 512]` scratch on the stack per call instead; see kernel_
 * main_rpi4.vani's own dhcp_* functions).
 *
 * Unlike ARP's cache or TCP's 2-slot connection table, this client is
 * a SINGLE instance -- no array/table needed, just 7 scalar u32
 * fields, matching kernel_main.vani's own dhcp_state_* accessor set
 * exactly (client_state/xid/offered_ip/server_ip/leased_ip/
 * lease_time/lease_start_tick).
 *
 * Same GNU `as` `.macro` technique round 89's tcp_state.S introduced
 * for its own repetitive get/set pairs, reused here for the same
 * reason (less error-prone than 14 hand-duplicated functions).
 *
 * AAPCS64 note (see [[feedback_aapcs_callee_saved_registers_asm]]):
 * every function below only uses x0-x15 as scratch and never calls
 * another function internally. */
.section ".bss"
.align 4
dhcp_state_client_state:   .word 0
dhcp_state_xid:            .word 0
dhcp_state_offered_ip:     .word 0
dhcp_state_server_ip:      .word 0
dhcp_state_leased_ip:      .word 0
dhcp_state_lease_time:     .word 0
dhcp_state_lease_start_tick: .word 0

.section ".text"

.macro DHCP_STATE_ACCESSOR name, sym
.global dhcp_state_get_\name
dhcp_state_get_\name:
    adrp x0, \sym
    add x0, x0, :lo12:\sym
    ldr w0, [x0]
    ret
.global dhcp_state_set_\name
dhcp_state_set_\name:
    adrp x1, \sym
    add x1, x1, :lo12:\sym
    str w0, [x1]
    mov x0, #0
    ret
.endm

DHCP_STATE_ACCESSOR client_state, dhcp_state_client_state
DHCP_STATE_ACCESSOR xid, dhcp_state_xid
DHCP_STATE_ACCESSOR offered_ip, dhcp_state_offered_ip
DHCP_STATE_ACCESSOR server_ip, dhcp_state_server_ip
DHCP_STATE_ACCESSOR leased_ip, dhcp_state_leased_ip
DHCP_STATE_ACCESSOR lease_time, dhcp_state_lease_time
DHCP_STATE_ACCESSOR lease_start_tick, dhcp_state_lease_start_tick
