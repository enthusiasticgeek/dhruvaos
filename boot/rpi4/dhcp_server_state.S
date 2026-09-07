/* Dhruva round 92 -- DHCP SERVER persistent state. Brand-new design,
 * no kernel_main.vani precedent to port (Pi 1 never built a DHCP
 * server) -- see project memory project_dhruva_dhcp_server_scope_
 * 2026_09_06.md for the full design rationale.
 *
 * A separate file from round 91's dhcp_state.S (the CLIENT), not a
 * shared one -- client and server are independent roles this project
 * may eventually run simultaneously (e.g. a future router-style WAN
 * client + LAN server), so keeping them as separate modules is the
 * right call now rather than a later untangling.
 *
 * A small FIXED lease table (4 slots), matching this project's own
 * established "small fixed arrays, not dynamic allocation" convention
 * (ARP's 8-slot cache, TCP's 2-slot connection table, the packet
 * filter's 8-slot rule table). Each slot: mac[6] (byte-accessed, same
 * reasoning as arp_state.S's own MAC bytes) + leased_ip/xid/state
 * (0=FREE, 1=OFFERED, 2=BOUND)/lease_start_tick, all u32. Server-wide
 * config (server_ip/pool_base_ip/pool_size/lease_time) is set once
 * via dhcp_server_set_config, not hardcoded -- a future real config
 * path is easier to add on top of an explicit call than a compile-
 * time constant.
 *
 * Same GNU `as` `.macro` technique rounds 89/91 already established
 * for repetitive get/set pairs.
 *
 * AAPCS64 note (see [[feedback_aapcs_callee_saved_registers_asm]]):
 * every function below only uses x0-x15 as scratch and never calls
 * another function internally. */
.section ".bss"
.align 4
dhcp_server_config_server_ip:   .word 0
dhcp_server_config_pool_base_ip: .word 0
dhcp_server_config_pool_size:   .word 0
dhcp_server_config_lease_time:  .word 0
.align 4
dhcp_server_lease_state:        .space 16  /* 4 slots * 4 bytes/u32 */
.align 4
dhcp_server_lease_ip:           .space 16
.align 4
dhcp_server_lease_xid:          .space 16
.align 4
dhcp_server_lease_start_tick:   .space 16
.align 4
dhcp_server_lease_mac:          .space 24  /* 4 slots * 6 bytes */

.section ".text"

/* u32 dhcp_server_set_config(u32 server_ip, u32 pool_base_ip,
 *                            u32 pool_size, u32 lease_time)
 * -- all 4 args fit in x0-x3, no stack spill on AArch64. */
.global dhcp_server_set_config
dhcp_server_set_config:
    adrp x4, dhcp_server_config_server_ip
    add x4, x4, :lo12:dhcp_server_config_server_ip
    str w0, [x4]
    adrp x4, dhcp_server_config_pool_base_ip
    add x4, x4, :lo12:dhcp_server_config_pool_base_ip
    str w1, [x4]
    adrp x4, dhcp_server_config_pool_size
    add x4, x4, :lo12:dhcp_server_config_pool_size
    str w2, [x4]
    adrp x4, dhcp_server_config_lease_time
    add x4, x4, :lo12:dhcp_server_config_lease_time
    str w3, [x4]
    mov x0, #0
    ret

.global dhcp_server_get_server_ip
dhcp_server_get_server_ip:
    adrp x0, dhcp_server_config_server_ip
    add x0, x0, :lo12:dhcp_server_config_server_ip
    ldr w0, [x0]
    ret

.global dhcp_server_get_pool_base_ip
dhcp_server_get_pool_base_ip:
    adrp x0, dhcp_server_config_pool_base_ip
    add x0, x0, :lo12:dhcp_server_config_pool_base_ip
    ldr w0, [x0]
    ret

.global dhcp_server_get_pool_size
dhcp_server_get_pool_size:
    adrp x0, dhcp_server_config_pool_size
    add x0, x0, :lo12:dhcp_server_config_pool_size
    ldr w0, [x0]
    ret

.global dhcp_server_get_lease_time
dhcp_server_get_lease_time:
    adrp x0, dhcp_server_config_lease_time
    add x0, x0, :lo12:dhcp_server_config_lease_time
    ldr w0, [x0]
    ret

/* u32 dhcp_server_reset(void) -- zero every lease slot's own state
 * (FREE) and its own lease_start_tick; ip/xid/mac contents don't need
 * zeroing, matching netif_state_reset's own convention (nothing reads
 * a FREE slot's other fields). Does NOT touch config -- a reset is
 * for clearing leases between self-test reruns, not re-configuring
 * the server. */
.global dhcp_server_reset
dhcp_server_reset:
    adrp x0, dhcp_server_lease_state
    add x0, x0, :lo12:dhcp_server_lease_state
    str wzr, [x0]
    str wzr, [x0, #4]
    str wzr, [x0, #8]
    str wzr, [x0, #12]
    adrp x1, dhcp_server_lease_start_tick
    add x1, x1, :lo12:dhcp_server_lease_start_tick
    str wzr, [x1]
    str wzr, [x1, #4]
    str wzr, [x1, #8]
    str wzr, [x1, #12]
    mov x0, #0
    ret

.macro DHCP_SERVER_LEASE_ACCESSOR name, sym
.global dhcp_server_get_\name
dhcp_server_get_\name:
    adrp x1, \sym
    add x1, x1, :lo12:\sym
    ldr w0, [x1, w0, uxtw #2]
    ret
.global dhcp_server_set_\name
dhcp_server_set_\name:
    adrp x2, \sym
    add x2, x2, :lo12:\sym
    str w1, [x2, w0, uxtw #2]
    mov x0, #0
    ret
.endm

DHCP_SERVER_LEASE_ACCESSOR lease_state, dhcp_server_lease_state
DHCP_SERVER_LEASE_ACCESSOR lease_ip, dhcp_server_lease_ip
DHCP_SERVER_LEASE_ACCESSOR lease_xid, dhcp_server_lease_xid
DHCP_SERVER_LEASE_ACCESSOR lease_start_tick, dhcp_server_lease_start_tick

/* u32 dhcp_server_get_lease_mac_byte(u32 index, u32 byte_idx) --
 * slot base is index*6, matching dhcp_server_lease_mac's own
 * 6-byte-per-entry layout. */
.global dhcp_server_get_lease_mac_byte
dhcp_server_get_lease_mac_byte:
    mov w2, #6
    mul w3, w0, w2
    add w3, w3, w1
    adrp x4, dhcp_server_lease_mac
    add x4, x4, :lo12:dhcp_server_lease_mac
    ldrb w0, [x4, w3, uxtw]
    ret

/* u32 dhcp_server_set_lease_mac_byte(u32 index, u32 byte_idx, u32 value) */
.global dhcp_server_set_lease_mac_byte
dhcp_server_set_lease_mac_byte:
    mov w3, #6
    mul w4, w0, w3
    add w4, w4, w1
    adrp x5, dhcp_server_lease_mac
    add x5, x5, :lo12:dhcp_server_lease_mac
    strb w2, [x5, w4, uxtw]
    mov x0, #0
    ret
