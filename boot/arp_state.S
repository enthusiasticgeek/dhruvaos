/* Dhruva Phase 6 -- ARP cache persistent state (ARM32).
 *
 * Same shape of problem as every other .bss-plus-accessor file in
 * this project: the ARP cache (IP -> MAC mappings learned from
 * replies) needs to survive across many separate calls from whatever
 * best-effort networking code eventually consults it, with no
 * top-level vani global to hold it instead.
 *
 * Every parameter here is deliberately `u32` (never `i64`), the same
 * defensive choice fs_buf.S already documents and netif_state.S's own
 * netif_set_slot_len bug (found via a live self-test failure, not by
 * inspection -- see that file's own comment) is a direct example of
 * getting wrong: a `u32` is a genuine single 32-bit AAPCS value,
 * needing exactly one register with no even-pair alignment padding to
 * account for, regardless of how many other u32 parameters precede
 * it in the same call. IP addresses and small counters/indices all
 * fit comfortably in 32 bits, so there's no reason to reach for `i64`
 * here at all and reintroduce that whole bug class.
 *
 * 8 entries, fixed-size, no eviction policy smarter than "overwrite
 * the oldest slot, round-robin" (tracked by next_slot below) -- a
 * demo-scoped cache for a demo-scoped stack, not a production ARP
 * implementation with real aging/timeouts. MAC bytes live in a plain
 * heap buffer (set once, like netif's own frame queue) so the actual
 * byte copying can stay in vani using the already-generic
 * buf_read_byte/buf_write_byte. */

.section ".bss"
.align 4
arp_cache_macs_buf_addr:
    .word 0             /* address of a 48-byte (8 * 6) buffer holding
                         * each entry's MAC, set once at boot */
arp_cache_ips:
    .word 0, 0, 0, 0, 0, 0, 0, 0   /* one u32 IP per entry; 0 means
                                    * "never used" (0.0.0.0 is never a
                                    * real host address to cache) */
arp_cache_count:
    .word 0             /* how many entries are actually populated,
                         * 0..8 */
arp_cache_next_slot:
    .word 0             /* round-robin overwrite pointer once full */

.section ".text"

.global arp_cache_set_macs_buf
arp_cache_set_macs_buf:
    ldr r1, =arp_cache_macs_buf_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global arp_cache_get_macs_buf
arp_cache_get_macs_buf:
    ldr r0, =arp_cache_macs_buf_addr
    ldr r0, [r0]
    bx lr

.global arp_cache_get_count
arp_cache_get_count:
    ldr r0, =arp_cache_count
    ldr r0, [r0]
    bx lr

.global arp_cache_set_count
arp_cache_set_count:
    ldr r1, =arp_cache_count
    str r0, [r1]
    mov r0, #0
    bx lr

.global arp_cache_get_next_slot
arp_cache_get_next_slot:
    ldr r0, =arp_cache_next_slot
    ldr r0, [r0]
    bx lr

.global arp_cache_set_next_slot
arp_cache_set_next_slot:
    ldr r1, =arp_cache_next_slot
    str r0, [r1]
    mov r0, #0
    bx lr

/* u32 arp_cache_get_ip(u32 index) */
.global arp_cache_get_ip
arp_cache_get_ip:
    ldr r1, =arp_cache_ips
    ldr r0, [r1, r0, lsl #2]
    bx lr

/* u32 arp_cache_set_ip(u32 index, u32 value) -- both u32, so index=r0,
 * value=r1 genuinely are adjacent single registers, unlike
 * netif_set_slot_len's i64 version of this same shape of function. */
.global arp_cache_set_ip
arp_cache_set_ip:
    ldr r2, =arp_cache_ips
    str r1, [r2, r0, lsl #2]
    mov r0, #0
    bx lr
