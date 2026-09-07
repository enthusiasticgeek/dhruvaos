/* Dhruva round 107 -- DHCP SERVER persistent state (ARM32). Pi 1
 * never had a DHCP server before this round; this is a direct port
 * of Pi 4/5's own boot/rpi4/dhcp_server_state.S (round 92) field
 * layout to ARM32/AAPCS32 -- the message-format ALGORITHM that
 * consumes this state (build_offer_ack/build_nak, the lease-table
 * lookup) already lives in the shared `netstack` kosh package
 * (round 106e), proven correct on Pi 4/5; only this file (persistent
 * storage) and kernel_main.vani's own netif/socket integration glue
 * (dhcp_server_init/handle_discover/handle_request/poll/send_reply)
 * are genuinely new for this port.
 *
 * A separate file from dhcp_state.S (the CLIENT) -- client and
 * server are independent roles, matching the same reasoning Pi 4/5's
 * own dhcp_server_state.S header comment already gives.
 *
 * A small FIXED lease table (4 slots), matching Pi 4/5's own choice
 * and this project's own established "small fixed arrays" convention
 * (ARP's 8-slot cache, the packet filter's 8-slot rule table). Each
 * slot: mac[6] (byte-accessed) + leased_ip/xid/state (0=FREE,
 * 1=OFFERED, 2=BOUND)/lease_start_tick, all u32.
 *
 * Every scalar field is deliberately `u32` (never `i64`), matching
 * dhcp_state.S's own defensive convention against the AAPCS register-
 * pairing bug netif_state.S's own netif_set_slot_len hit (see that
 * file's own comment) -- a u32 is a genuine single AAPCS32 register
 * regardless of how many other u32 parameters precede it.
 *
 * AAPCS32 note (see [[feedback_aapcs_callee_saved_registers_asm]] --
 * a real bug class this project has hit 4 times already): every
 * function below only uses r0-r3 as scratch and never calls another
 * function internally, matching every other state-accessor file in
 * this project. */

.section ".bss"
.align 4
dhcp_server_config_server_ip:
    .word 0
dhcp_server_config_pool_base_ip:
    .word 0
dhcp_server_config_pool_size:
    .word 0
dhcp_server_config_lease_time:
    .word 0
.align 4
dhcp_server_lease_state:
    .word 0, 0, 0, 0            /* 4 slots * 4 bytes/u32 */
.align 4
dhcp_server_lease_ip:
    .word 0, 0, 0, 0
.align 4
dhcp_server_lease_xid:
    .word 0, 0, 0, 0
.align 4
dhcp_server_lease_start_tick:
    .word 0, 0, 0, 0
.align 4
dhcp_server_lease_mac:
    .space 24                   /* 4 slots * 6 bytes */

.section ".text"

/* u32 dhcp_server_set_config(u32 server_ip, u32 pool_base_ip,
 *                            u32 pool_size, u32 lease_time) */
.global dhcp_server_set_config
dhcp_server_set_config:
    ldr r3, =dhcp_server_config_server_ip
    str r0, [r3]
    ldr r3, =dhcp_server_config_pool_base_ip
    str r1, [r3]
    ldr r3, =dhcp_server_config_pool_size
    str r2, [r3]
    ldr r0, =dhcp_server_config_lease_time
    ldr r1, [sp]                /* 5th arg (lease_time) -- stack-spilled per AAPCS32's 4-register limit */
    str r1, [r0]
    mov r0, #0
    bx lr

.global dhcp_server_get_server_ip
dhcp_server_get_server_ip:
    ldr r0, =dhcp_server_config_server_ip
    ldr r0, [r0]
    bx lr

.global dhcp_server_get_pool_base_ip
dhcp_server_get_pool_base_ip:
    ldr r0, =dhcp_server_config_pool_base_ip
    ldr r0, [r0]
    bx lr

.global dhcp_server_get_pool_size
dhcp_server_get_pool_size:
    ldr r0, =dhcp_server_config_pool_size
    ldr r0, [r0]
    bx lr

.global dhcp_server_get_lease_time
dhcp_server_get_lease_time:
    ldr r0, =dhcp_server_config_lease_time
    ldr r0, [r0]
    bx lr

/* u32 dhcp_server_reset(void) -- zero every lease slot's own state
 * (FREE) and lease_start_tick; ip/xid/mac contents don't need
 * clearing since a FREE slot's own stale ip/xid/mac is never read by
 * any real caller (find_lease_by_mac/find_free_slot only ever
 * examine state), matching Pi 4/5's own reset semantics exactly --
 * used for clearing leases between self-test reruns, not
 * re-configuring the pool. */
.global dhcp_server_reset
dhcp_server_reset:
    ldr r0, =dhcp_server_lease_state
    mov r1, #0
    str r1, [r0, #0]
    str r1, [r0, #4]
    str r1, [r0, #8]
    str r1, [r0, #12]
    ldr r0, =dhcp_server_lease_start_tick
    str r1, [r0, #0]
    str r1, [r0, #4]
    str r1, [r0, #8]
    str r1, [r0, #12]
    mov r0, #0
    bx lr

/* u32 dhcp_server_get_lease_state(u32 index) */
.global dhcp_server_get_lease_state
dhcp_server_get_lease_state:
    ldr r1, =dhcp_server_lease_state
    ldr r0, [r1, r0, lsl #2]
    bx lr

/* u32 dhcp_server_set_lease_state(u32 index, u32 value) */
.global dhcp_server_set_lease_state
dhcp_server_set_lease_state:
    ldr r2, =dhcp_server_lease_state
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global dhcp_server_get_lease_ip
dhcp_server_get_lease_ip:
    ldr r1, =dhcp_server_lease_ip
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global dhcp_server_set_lease_ip
dhcp_server_set_lease_ip:
    ldr r2, =dhcp_server_lease_ip
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global dhcp_server_get_lease_xid
dhcp_server_get_lease_xid:
    ldr r1, =dhcp_server_lease_xid
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global dhcp_server_set_lease_xid
dhcp_server_set_lease_xid:
    ldr r2, =dhcp_server_lease_xid
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

.global dhcp_server_get_lease_start_tick
dhcp_server_get_lease_start_tick:
    ldr r1, =dhcp_server_lease_start_tick
    ldr r0, [r1, r0, lsl #2]
    bx lr

.global dhcp_server_set_lease_start_tick
dhcp_server_set_lease_start_tick:
    ldr r2, =dhcp_server_lease_start_tick
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr

/* u32 dhcp_server_get_lease_mac_byte(u32 index, u32 byte_idx) --
 * slot base is index*6, matching dhcp_server_lease_mac's own 6-byte-
 * per-entry layout. index*6 computed as (index*3)*2 via shift+add
 * (deliberately avoiding MUL's own Rd/Rm-overlap restriction
 * entirely, rather than relying on ARMv6+ having relaxed it -- ADD/
 * LSL have no such restriction on any ARM version). r0=index,
 * r1=byte_idx in; only r0-r3 used. */
.global dhcp_server_get_lease_mac_byte
dhcp_server_get_lease_mac_byte:
    add r0, r0, r0, lsl #1        /* r0 = index*3 (index + index<<1) */
    lsl r0, r0, #1                 /* r0 = index*6 */
    add r0, r0, r1                 /* r0 = index*6 + byte_idx (offset) */
    ldr r1, =dhcp_server_lease_mac
    ldrb r0, [r1, r0]
    bx lr

/* u32 dhcp_server_set_lease_mac_byte(u32 index, u32 byte_idx, u32 value) --
 * same index*6 computation as the getter above. r0=index, r1=byte_idx,
 * r2=value in; only r0-r2 used. */
.global dhcp_server_set_lease_mac_byte
dhcp_server_set_lease_mac_byte:
    add r0, r0, r0, lsl #1        /* r0 = index*3 */
    lsl r0, r0, #1                 /* r0 = index*6 */
    add r0, r0, r1                 /* r0 = index*6 + byte_idx (offset) */
    ldr r1, =dhcp_server_lease_mac
    strb r2, [r1, r0]
    mov r0, #0
    bx lr
