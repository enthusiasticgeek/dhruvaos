/* Dhruva Phase 6 -- generic netif abstraction's persistent queue state
 * (ARM32).
 *
 * DHRUVA_ARCHITECTURE.md §4's "get-go hook": "A generic netif
 * abstraction (send/receive a raw frame, MTU, MAC address) in the
 * kernel layer -- just an interface, no implementation. Both the
 * LAN9512 wired path and the WiFi dongle plug into the same
 * upper-stack path without a redesign." This file backs the ONE
 * implementation that exists so far -- a loopback netif, used to build
 * and test everything above it (ARP/IPv4/UDP/TCP) under QEMU without
 * needing real network hardware at all, per §4's own "what QEMU
 * actually validates" note.
 *
 * Same shape of problem as every other .bss-plus-accessor file in
 * this project: the actual frame bytes live in a plain heap buffer
 * (allocated once, in kernel_main(), via dhruva_alloc_bytes, then
 * handed to netif_set_queue_buf below) so the real byte-copying logic
 * can stay in vani using the already-generic buf_read_byte/
 * buf_write_byte (dharafs_buf.S) -- only the buffer's OWN address and the
 * small ring-queue bookkeeping (head/tail/count, per-slot lengths)
 * need a persistent home outside vani's call-stack-only world.
 *
 * 4 slots, netif_frame_slot_size() bytes each (kernel_main.vani) --
 * 1514 bytes as of round 66 (a real 1500-byte Ethernet MTU plus the
 * 14-byte header), previously a hardcoded 512 that silently dropped
 * real-world frames like a multi-option DHCPOFFER (see docs/TODO.md's
 * own bug entry and netif_frame_slot_size's own comment for the full
 * fix). An explicit count (not just comparing head and tail) is what
 * tells "empty" and "full" apart unambiguously, since with only 4
 * slots head could otherwise equal tail in either case. */

.section ".bss"
.align 4
netif_queue_buf_addr:
    .word 0            /* address of the 4*netif_frame_slot_size()
                         * (6056 bytes as of round 66) frame storage
                         * buffer, set once at boot */
netif_queue_len:
    .word 0, 0, 0, 0    /* per-slot frame length; only meaningful for
                         * slots between tail and head */
netif_queue_head:
    .word 0             /* next slot a send writes into */
netif_queue_tail:
    .word 0             /* next slot a recv reads from */
netif_queue_count:
    .word 0             /* how many slots currently hold a real frame */

.section ".text"

.global netif_set_queue_buf
netif_set_queue_buf:
    ldr r1, =netif_queue_buf_addr
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

.global netif_get_queue_buf
netif_get_queue_buf:
    ldr r0, =netif_queue_buf_addr
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_get_head
netif_get_head:
    ldr r0, =netif_queue_head
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_get_tail
netif_get_tail:
    ldr r0, =netif_queue_tail
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global netif_get_count
netif_get_count:
    ldr r0, =netif_queue_count
    ldr r0, [r0]
    mov r1, #0
    bx lr

/* i64 netif_get_slot_len(i64 slot_index) */
.global netif_get_slot_len
netif_get_slot_len:
    ldr r1, =netif_queue_len
    ldr r0, [r1, r0, lsl #2]
    mov r1, #0
    bx lr

/* i64 netif_set_slot_len(i64 slot_index, i64 value) -- BUG (found via
 * a real, live self-test failure, not by inspection): two `i64`
 * parameters means AAPCS's 64-bit register-pair rule applies to BOTH,
 * not just the first -- slot_index occupies r0:r1, so `value` actually
 * arrives in r2:r3, not r1 as a naive "second argument = second
 * register" reading would assume. The original code read r1 (the
 * unused, always-zero high word of slot_index) instead of r2 (the
 * real value), silently storing 0 for every slot length regardless of
 * what was actually passed in. Every OTHER function in this file
 * either takes zero parameters, a lone i64 (which always starts at
 * r0 with nothing before it to shift it), or a `mut ref i64` pointer
 * (single-register regardless, immune to this rule) -- this was the
 * only one with two i64s, and the only one this bug could hide in.
 * r12 (IP) is used as the address scratch register here specifically
 * so as not to further confuse which register holds which argument. */
.global netif_set_slot_len
netif_set_slot_len:
    ldr r12, =netif_queue_len
    str r2, [r12, r0, lsl #2]
    mov r0, #0
    mov r1, #0
    bx lr

/* i64 netif_advance_head() -- head = (head+1) mod 4, count += 1.
 * Caller's own responsibility to have already checked count < 4. */
.global netif_advance_head
netif_advance_head:
    ldr r0, =netif_queue_head
    ldr r1, [r0]
    add r1, r1, #1
    and r1, r1, #3
    str r1, [r0]
    ldr r0, =netif_queue_count
    ldr r1, [r0]
    add r1, r1, #1
    str r1, [r0]
    mov r0, #0
    mov r1, #0
    bx lr

/* i64 netif_advance_tail() -- tail = (tail+1) mod 4, count -= 1.
 * Caller's own responsibility to have already checked count > 0. */
.global netif_advance_tail
netif_advance_tail:
    ldr r0, =netif_queue_tail
    ldr r1, [r0]
    add r1, r1, #1
    and r1, r1, #3
    str r1, [r0]
    ldr r0, =netif_queue_count
    ldr r1, [r0]
    sub r1, r1, #1
    str r1, [r0]
    mov r0, #0
    mov r1, #0
    bx lr
