/* Dhruva round 87 -- Phase A step 2 of the networking/SSH/WiFi scope
 * (see project memory project_dhruva_networking_ssh_wifi_scope_
 * 2026_09_06.md): ARP (RFC 826) cache state, exercised against round
 * 86's loopback netif.
 *
 * Same shape as boot/rpi4/netif_state.S / shell_state.S: persistent
 * mutable state lives here in asm (vani on this port only ever holds
 * transient/local state), with byte/word-level accessors. Mirrors
 * kernel_main.vani's own arp_cache_* design (an 8-entry round-robin
 * cache, no real aging/timeouts -- a demo-scoped cache, not a
 * production one) but replaces that side's `arp_cache_get_macs_buf()
 * -> mut ref i64` raw-pointer-into-a-heap-buffer accessor with a
 * direct per-byte accessor (`arp_cache_get_mac_byte`/`_set_mac_byte`),
 * consistent with this port's "no heap, no raw pointer crossing the
 * vani/asm boundary" discipline netif_state.S already established.
 * The actual lookup/insert ALGORITHM (round-robin-once-full, update-
 * in-place-if-already-cached) is written in vani, in kernel_main_
 * rpi4.vani, calling these low-level accessors -- same split as Pi
 * 1's own arp_cache_lookup/arp_cache_insert (logic in vani, storage
 * in asm), not a re-design.
 *
 * AAPCS64 note (see [[feedback_aapcs_callee_saved_registers_asm]]):
 * every function below only uses x0-x15 as scratch and never calls
 * another function internally. */
.section ".bss"
.align 4
arp_cache_count_state:     .word 0
arp_cache_next_slot_state: .word 0
.align 4
arp_cache_ip_table:  .space 32  /* 8 entries * 4 bytes/u32 */
.align 4
arp_cache_mac_table: .space 48  /* 8 entries * 6 bytes */

.section ".text"

/* u32 arp_cache_reset(void) -- zero count/next_slot. Cache contents
 * (ip/mac tables) don't need zeroing: nothing reads slot N until
 * count > N, exactly like netif_state_reset leaves the queue buffers
 * untouched. */
.global arp_cache_reset
arp_cache_reset:
    adrp x0, arp_cache_count_state
    add x0, x0, :lo12:arp_cache_count_state
    str wzr, [x0]
    adrp x1, arp_cache_next_slot_state
    add x1, x1, :lo12:arp_cache_next_slot_state
    str wzr, [x1]
    mov x0, #0
    ret

.global arp_cache_get_count
arp_cache_get_count:
    adrp x0, arp_cache_count_state
    add x0, x0, :lo12:arp_cache_count_state
    ldr w0, [x0]
    ret

/* u32 arp_cache_set_count(u32 count) */
.global arp_cache_set_count
arp_cache_set_count:
    adrp x1, arp_cache_count_state
    add x1, x1, :lo12:arp_cache_count_state
    str w0, [x1]
    mov x0, #0
    ret

.global arp_cache_get_next_slot
arp_cache_get_next_slot:
    adrp x0, arp_cache_next_slot_state
    add x0, x0, :lo12:arp_cache_next_slot_state
    ldr w0, [x0]
    ret

/* u32 arp_cache_set_next_slot(u32 slot) */
.global arp_cache_set_next_slot
arp_cache_set_next_slot:
    adrp x1, arp_cache_next_slot_state
    add x1, x1, :lo12:arp_cache_next_slot_state
    str w0, [x1]
    mov x0, #0
    ret

/* u32 arp_cache_get_ip(u32 index) */
.global arp_cache_get_ip
arp_cache_get_ip:
    adrp x1, arp_cache_ip_table
    add x1, x1, :lo12:arp_cache_ip_table
    ldr w0, [x1, w0, uxtw #2]
    ret

/* u32 arp_cache_set_ip(u32 index, u32 value) */
.global arp_cache_set_ip
arp_cache_set_ip:
    adrp x2, arp_cache_ip_table
    add x2, x2, :lo12:arp_cache_ip_table
    str w1, [x2, w0, uxtw #2]
    mov x0, #0
    ret

/* u32 arp_cache_get_mac_byte(u32 index, u32 byte_idx) -- slot base is
 * index*6, matching arp_cache_mac_table's own 6-byte-per-entry
 * layout. */
.global arp_cache_get_mac_byte
arp_cache_get_mac_byte:
    mov w2, #6
    mul w3, w0, w2          /* w3 = index * 6 */
    add w3, w3, w1          /* w3 += byte_idx */
    adrp x4, arp_cache_mac_table
    add x4, x4, :lo12:arp_cache_mac_table
    ldrb w0, [x4, w3, uxtw]
    ret

/* u32 arp_cache_set_mac_byte(u32 index, u32 byte_idx, u32 value) */
.global arp_cache_set_mac_byte
arp_cache_set_mac_byte:
    mov w3, #6
    mul w4, w0, w3          /* w4 = index * 6 */
    add w4, w4, w1          /* w4 += byte_idx */
    adrp x5, arp_cache_mac_table
    add x5, x5, :lo12:arp_cache_mac_table
    strb w2, [x5, w4, uxtw]
    mov x0, #0
    ret
