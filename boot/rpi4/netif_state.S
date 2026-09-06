/* Dhruva round 86 -- Phase A step 1 of the networking/SSH/WiFi scope
 * (see project memory project_dhruva_networking_ssh_wifi_scope_
 * 2026_09_06.md): the smallest useful netif abstraction on the Pi 4/5
 * port. Loopback/synthetic frames only -- no real GENET or USB/XHCI
 * NIC backend exists on this port yet, deliberately mirroring how
 * kernel_main.vani's own netif_send_frame/netif_recv_frame fall
 * through to their loopback queue whenever no real hardware backend
 * (CDC-ECM/LAN9512) was enumerated. Confirmed before writing this
 * file: QEMU's raspi4b machine has NO network device model at all
 * (`-device help` lists no genet/bcm ethernet part, `-M raspi4b,help`
 * exposes no NIC option), so a real backend has no QEMU verification
 * path regardless -- the protocol-logic-first split this scope
 * memory documents.
 *
 * Persistent mutable state (the frame queue itself) lives here in
 * asm, not as vani globals, mirroring shell_state.S's own precedent
 * exactly -- vani on this port only ever holds transient/local state
 * (see kernel_main_rpi4.vani's own SHA-256 arrays), never a value
 * that must survive across separate top-level calls. Byte-at-a-time
 * accessors (stage/recv one byte per call) mirror shell_get_line_byte
 * /shell_rx_push_char's own shape rather than passing a raw pointer
 * across the vani/asm boundary, which this port has never done
 * anywhere else.
 *
 * Design: a 4-slot x 512-byte ring buffer (NETIF_QUEUE_SLOTS x
 * NETIF_SLOT_SIZE below). 512, not kernel_main.vani's own current
 * round-66 real-1514-byte-Ethernet-MTU sizing, deliberately -- that
 * Pi 1 side itself started at exactly this same 512 "deliberately
 * smaller than a real Ethernet MTU, since nothing this project could
 * test end-to-end under QEMU needed a full-size frame" (round 66's
 * own comment) and was only raised once a real DHCPOFFER actually
 * needed more. Nothing in this round's self-test needs more than 16
 * bytes; raise this the same way Pi 1's netif_frame_slot_size() was
 * raised, once a real later round's payload actually needs it, not
 * speculatively now. Also a practical vani-language constraint, not
 * just a style echo of Pi 1's history: vani has no array-repeat
 * literal syntax (`[0; N]`) and `let` requires a full initializer, so
 * every fixed-size local array needs either a fully hand-enumerated
 * literal or a helper function returning one -- kernel_main_rpi4.vani
 * uses the latter (`netif_zero_frame_rpi4`), and 512 elements is a
 * far more tractable one-time literal than 1514. Plus a separate
 * staging buffer a caller builds a frame into one byte at a time
 * before committing it as a whole. head/tail/count implement the same
 * full-queue-drops/empty-queue-returns-nothing semantics as
 * kernel_main.vani's own netif_send_frame/netif_recv_frame.
 *
 * AAPCS64 note (see [[feedback_aapcs_callee_saved_registers_asm]] --
 * this class of bug has recurred multiple times on this project):
 * every function below only ever uses x0-x15 as scratch and never
 * calls another function internally, so there is no callee-saved
 * (x19-x28) register to preserve and no risk of clobbering a live
 * caller value across a call boundary. */
.section ".bss"
.align 4
netif_head:      .word 0
netif_tail:      .word 0
netif_count:     .word 0
.align 4
netif_slot_len:  .space 16   /* 4 slots * 4 bytes/u32 */
.align 4
netif_queue_buf: .space 2048 /* 4 slots * 512 bytes */
.align 4
netif_stage_buf: .space 512

.section ".text"

/* u32 netif_state_reset(void) -- zero head/tail/count. Called once at
 * init and again at the start of the self-test so repeated `netif`
 * shell-command reruns always start from a clean, empty queue. */
.global netif_state_reset
netif_state_reset:
    adrp x0, netif_head
    add x0, x0, :lo12:netif_head
    str wzr, [x0]
    adrp x1, netif_tail
    add x1, x1, :lo12:netif_tail
    str wzr, [x1]
    adrp x2, netif_count
    add x2, x2, :lo12:netif_count
    str wzr, [x2]
    mov x0, #0
    ret

/* u32 netif_state_count(void) -- how many frames are queued right now. */
.global netif_state_count
netif_state_count:
    adrp x0, netif_count
    add x0, x0, :lo12:netif_count
    ldr w0, [x0]
    ret

/* u32 netif_state_stage_byte(u32 offset, u32 value) -- writes one byte
 * into the staging buffer at `offset`. Caller (vani) is always the one
 * that bounds `offset` against NETIF_SLOT_SIZE before calling (via the
 * same "frame_len > slot size -> reject before writing anything" check
 * kernel_main.vani's own netif_send_frame already uses), so no bounds
 * check is repeated here -- same trust boundary shell_rx_push_char's
 * own offset handling already relies on its caller for. */
.global netif_state_stage_byte
netif_state_stage_byte:
    adrp x2, netif_stage_buf
    add x2, x2, :lo12:netif_stage_buf
    strb w1, [x2, w0, uxtw]
    mov x0, #0
    ret

/* i64 netif_state_commit_send(u32 frame_len) -- copies the staged
 * frame into the next free queue slot. Returns 0 on success, -1 if
 * all 4 slots are already full (the frame is dropped, matching a real
 * NIC's best-effort behavior under congestion -- same semantics as
 * kernel_main.vani's own netif_send_frame queue-full case). */
.global netif_state_commit_send
netif_state_commit_send:
    adrp x1, netif_count
    add x1, x1, :lo12:netif_count
    ldr w2, [x1]
    cmp w2, #4
    b.ge .Lncs_full

    adrp x3, netif_head
    add x3, x3, :lo12:netif_head
    ldr w4, [x3]            /* w4 = head index (0..3) */

    mov x5, #512
    umull x6, w4, w5        /* x6 = head * 512 = slot base offset */

    adrp x7, netif_queue_buf
    add x7, x7, :lo12:netif_queue_buf
    add x7, x7, x6          /* x7 = &queue_buf[slot base] */

    adrp x8, netif_stage_buf
    add x8, x8, :lo12:netif_stage_buf

    mov w9, #0               /* i = 0 */
.Lncs_copy_loop:
    cmp w9, w0
    b.ge .Lncs_copy_done
    ldrb w10, [x8, w9, uxtw]
    strb w10, [x7, w9, uxtw]
    add w9, w9, #1
    b .Lncs_copy_loop
.Lncs_copy_done:

    adrp x11, netif_slot_len
    add x11, x11, :lo12:netif_slot_len
    str w0, [x11, w4, uxtw #2]   /* slot_len[head] = frame_len */

    add w4, w4, #1
    and w4, w4, #3           /* head = (head + 1) % 4 */
    str w4, [x3]

    add w2, w2, #1
    str w2, [x1]

    mov x0, #0
    ret

.Lncs_full:
    mov x0, #-1
    ret

/* i64 netif_state_recv_len(void) -- length of the frame currently at
 * the tail (the one the next recv_byte/recv_advance calls apply to),
 * or -1 if the queue is empty. */
.global netif_state_recv_len
netif_state_recv_len:
    adrp x0, netif_count
    add x0, x0, :lo12:netif_count
    ldr w1, [x0]
    cbnz w1, .Lnrl_have
    mov x0, #-1
    ret
.Lnrl_have:
    adrp x2, netif_tail
    add x2, x2, :lo12:netif_tail
    ldr w3, [x2]
    adrp x4, netif_slot_len
    add x4, x4, :lo12:netif_slot_len
    ldr w0, [x4, w3, uxtw #2]
    ret

/* u32 netif_state_recv_byte(u32 offset) -- reads one byte from the
 * frame currently at the tail. */
.global netif_state_recv_byte
netif_state_recv_byte:
    adrp x1, netif_tail
    add x1, x1, :lo12:netif_tail
    ldr w2, [x1]
    mov x3, #512
    umull x4, w2, w3
    adrp x5, netif_queue_buf
    add x5, x5, :lo12:netif_queue_buf
    add x5, x5, x4
    ldrb w0, [x5, w0, uxtw]
    ret

/* u32 netif_state_recv_advance(void) -- pops the frame at the tail
 * (advances tail, decrements count). Called once the caller has
 * finished reading every byte of the current frame (or has decided to
 * drop it, e.g. because it's bigger than the caller's own buffer). */
.global netif_state_recv_advance
netif_state_recv_advance:
    adrp x0, netif_tail
    add x0, x0, :lo12:netif_tail
    ldr w1, [x0]
    add w1, w1, #1
    and w1, w1, #3
    str w1, [x0]
    adrp x2, netif_count
    add x2, x2, :lo12:netif_count
    ldr w3, [x2]
    sub w3, w3, #1
    str w3, [x2]
    mov x0, #0
    ret
