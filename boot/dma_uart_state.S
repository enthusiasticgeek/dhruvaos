/* DMA-driven UART TX (2026-09-27), per the user's own explicit
 * direction: "i suggest dma be used to save cpu cycles ... use arm
 * reference if needed apart from bcm for mmu/cache or dma". UART TX
 * has been blocking/polled PIO since Phase 0 -- ~87us/byte at this
 * project's own established baud rate, a real, previously-quantified
 * cost (see the UART-corruption and diagnostic-timing-confound
 * investigations, 2026-09-25/26) that CPU cycles spent busy-waiting
 * for the PL011 TX FIFO could instead go to real task work.
 *
 * Every register/bit value here comes from Broadcom's own official
 * "BCM2835 ARM Peripherals" datasheet (fetched and grepped directly,
 * not recalled from memory or copied from a driver's own encoding
 * without cross-checking):
 *   - DMA Controller Register Address Map (section 4.2.1.2): channel
 *     N's register set lives at DMA_BASE + N*0x100; CS at +0x00,
 *     CONBLK_AD at +0x04. Global ENABLE register (one bit per
 *     channel) at DMA_BASE + 0xff0.
 *   - Control Block Data Structure (section 4.2.1.1): 8 words (256
 *     bits), MUST start at a 256-bit (32-byte) aligned address --
 *     word0=TI, word1=SOURCE_AD, word2=DEST_AD, word3=TXFR_LEN,
 *     word4=STRIDE, word5=NEXTCONBK, words6-7=reserved (set to zero).
 *   - Transfer Information (TI) bit layout (section 4.2.1.2, the TI
 *     register description): bit3=WAIT_RESP, bit4=DEST_INC,
 *     bit5=DEST_WIDTH, bit6=DEST_DREQ, bit8=SRC_INC, bit9=SRC_WIDTH,
 *     bits20:16=PERMAP. WIDTH bits are 0=32-bit/1=128-bit -- there is
 *     NO native byte-width mode on this DMA engine at all.
 *   - Peripheral DREQ Signals table (section 4.2.1.3): UART TX = 12
 *     (UART RX = 14, matching this same table's SD HOST=13/e.MMC=11
 *     already cross-referenced during the SD investigation).
 *
 * The one real correctness risk this whole feature hinges on: with
 * DEST_WIDTH=0 (32-bit, the only option besides 128-bit) writing to a
 * byte-oriented peripheral's data register, does software need to pad
 * each outgoing byte into its own 4-byte slot, or can a plain packed
 * byte buffer be sent directly? Verified against TWO independent real
 * sources before writing this file, not assumed: (1) the datasheet's
 * own DMA overview text -- "The DMA can deal with byte aligned
 * transfers and will minimise bus traffic by buffering and packing
 * misaligned accesses" -- states directly that the hardware itself
 * handles this; (2) real Linux's own drivers/dma/bcm2835-dma.c (the
 * actual, hardened generic DMA engine driver every Raspberry Pi
 * distribution's own UART DMA path runs through) sends plain,
 * tightly-packed byte-count buffers with no 4-byte padding, relying
 * on exactly this hardware capability. A plain byte array is correct.
 *
 * QEMU note (UPDATED 2026-10-16, task #357): the original claim here
 * -- that QEMU 10.0.13's own bcm2835-dma.c model DOES perform real
 * guest-physical-address data movement (ldl_le_phys/stl_le_phys)
 * reaching MMIO-backed regions including UART0 DR, unlike SDHOST/
 * GPIO-pull -- was based on reading that model's own source, not a
 * confirmed end-to-end test: dma_uart_tx_self_test below (a small,
 * fixed, standalone call, gated behind boot_debug_enabled) DOES still
 * pass cleanly under QEMU, proving the CB/CS mechanics themselves are
 * sound and real guest-physical movement does happen. But the FIRST
 * real adoption of this driver through kernel_main.vani's own
 * uart_puts (task #357) hits "qemu-system-arm: warning: Blocked
 * re-entrant IO on MemoryRegion: bcm2835-dma at addr: 0x0" and hangs
 * the whole system -- confirmed via a clean A/B (disabling only that
 * one new call site let the self-test below run successfully moments
 * later in the identical boot) that this is specific to that call
 * site/context, not a general failure of the driver or a QEMU
 * limitation on reaching UART0 at all. Root cause not yet isolated.
 * Net effect: this driver joins SDHOST/GPIO-pull on this project's
 * own "something about real adoption is untestable under QEMU, needs
 * real-HW validation" list, just via a narrower, not-yet-understood
 * mechanism rather than an outright missing MMIO path. See uart_puts's
 * own UART_DMA_ADOPT_FOR_REAL_HARDWARE comment (kernel_main.vani) for
 * the full finding and the real-HW-only gate this led to.
 *
 * QEMU's own DMA model does NOT implement DREQ pacing at all (it
 * always runs a CB to completion at full speed) -- harmless for
 * correctness (real hardware paces itself; QEMU just doesn't need
 * to), but means QEMU can never exercise this driver's own DREQ-gated
 * timing, only whether the bytes arrive correctly and in order.
 *
 * DMA channel 5 chosen: arbitrary but deliberate -- this project uses
 * no DMA channel anywhere yet, so any channel is free, but channel 0
 * is the one channel occasionally referenced in bare-metal Pi
 * community writeups as touched transiently by GPU firmware before
 * the ARM core starts; channel 5 avoids that already-resolved-by-then
 * concern for zero cost. */

.section ".bss"
.align 4
.global uart_dma_ready
uart_dma_ready:
    .word 0    /* Task #357: set once dma_uart_init() has run AND
                * uart_dma_scratch (boot/scratch_state.S) is allocated
                * -- uart_puts is called heavily from the very first
                * boot checkpoint onward, long before either is ready,
                * so it needs an explicit flag to know when it's safe
                * to use the DMA path rather than assuming call-order
                * like every other scratch buffer in this project does
                * (those are all only ever read after their one real
                * init point; uart_puts cannot make that assumption). */

/* TASK #357 real-HW follow-up (2026-10-17): the first real-HW trial
 * hung the board 3/3 times inside dma_uart_init() itself, right at the
 * channel-5 RESET write, invisible under QEMU (34 prior rounds never
 * caught it) -- QEMU's DMA model has no VideoCore-firmware-side
 * activity to collide with. Root cause (not yet 100% proven on THIS
 * board's specific firmware, but well-evidenced): per real Linux's own
 * drivers/dma/bcm2835-dma.c (rpi-6.6.y, probe function), DMA channels
 * are NOT a pure software free-for-all on real hardware -- the
 * VideoCore GPU firmware actively reserves some channels for its own
 * use, and WHICH ones is firmware-version-specific, which is exactly
 * why Linux never hardcodes a channel: it reads a `brcm,dma-channel-
 * mask` devicetree property that the firmware itself populates via the
 * mailbox property tag RPI_FIRMWARE_GET_DMA_CHANNELS (0x00060001,
 * confirmed in raspberrypi-firmware.h). This project has no
 * devicetree, so dma_uart_init() below now calls that same tag
 * directly (reusing boot/fb_state.S's own already-verified
 * mbox_property_call transport, channel 8) and picks a channel the
 * firmware itself reports as available, instead of the old hardcoded
 * "channel 5, arbitrary but free" choice -- a real, unverified
 * assumption this exact bug disproved. */
.align 4
.global dma_uart_channel_valid
dma_uart_channel_valid:
    .word 0    /* 0 = no channel selected yet / none available (the
                * natural .bss zero-default -- `.bss` can't hold a
                * non-zero initializer, caught by the assembler itself
                * on the first build attempt here), 1 once dma_uart_
                * init finds a real firmware-safe channel. Every one of
                * dma_uart_tx_start/_busy/dma_ram_copy_test checks this
                * FIRST and refuses to touch any DMA register at all
                * while it's 0 -- not just a documented precondition,
                * an enforced one, since dma_uart_channel_val alone
                * (0 by default, a legitimate channel number) can't
                * distinguish "channel 0 selected" from "never selected". */
.global dma_uart_channel_val
dma_uart_channel_val:
    .word 0    /* meaningless until dma_uart_channel_valid == 1 */

.align 4    /* mailbox buffer alignment requirement -- see fb_mbox_buf's
             * own comment (boot/fb_state.S): mbox_property_call encodes
             * (buf_addr & ~0xF) | channel, so the low 4 bits must
             * already be zero. 4-word layout is exactly this call's
             * real size (no padding needed): buf_size, req/resp code,
             * tag id, value-buffer size, req/resp length, one value
             * word, end tag -- 7 words = 28 bytes, comfortably within
             * a 32-byte reservation. */
dma_mbox_buf:
    .space 32

.align 5    /* 32-byte (256-bit) alignment -- the DMA Control Block's
             * own hard requirement (section 4.2.1.1), not a general
             * project convention. */
.global dma_uart_cb
dma_uart_cb:
    .word 0    /* TI */
    .word 0    /* SOURCE_AD */
    .word 0    /* DEST_AD */
    .word 0    /* TXFR_LEN */
    .word 0    /* STRIDE (2D mode only, unused -- linear transfer) */
    .word 0    /* NEXTCONBK -- always 0: single CB, no chaining, so
                * ACTIVE auto-clears exactly when this transfer (and
                * only this transfer) completes, a clean busy signal. */
    .word 0    /* reserved */
    .word 0    /* reserved */

.section ".text"

/* dma_uart_init() -> i64 -- one-time setup, called once at boot before
 * any dma_uart_tx_start call. TASK #357 real-HW follow-up (2026-10-17,
 * see dma_uart_channel_val's own header comment for the full "why"):
 * first queries the VideoCore firmware's own RPI_FIRMWARE_GET_DMA_
 * CHANNELS mailbox tag (0x00060001) for a bitmask of channels the
 * firmware itself reports safe to use, picks the lowest set bit, and
 * only THEN resets/enables that channel (RESET bit, W1SC, self-
 * clearing per the datasheet's own CS register description) -- never
 * the old hardcoded "channel 5, arbitrary but free" assumption. Returns
 * 0 on success (dma_uart_channel_val holds the real selected channel).
 * Returns 1 if the mailbox call itself failed OR the firmware reported
 * no available channel at all -- dma_uart_channel_valid stays at its
 * .bss zero-default and NO DMA hardware register is ever touched in
 * that case; the caller (kernel_main.vani) must not set uart_dma_ready
 * in this case, same fail-safe-to-PIO contract every other failure
 * path here already has. */
.global dma_uart_init
dma_uart_init:
    push {r4, r5, r6, lr}

    ldr r4, =dma_mbox_buf
    mov r0, #28
    str r0, [r4, #0]       /* buf_size (bytes) */
    mov r0, #0
    str r0, [r4, #4]       /* req/resp code: 0 = process request */
    ldr r0, =0x00060001    /* tag: RPI_FIRMWARE_GET_DMA_CHANNELS */
    str r0, [r4, #8]
    mov r0, #4
    str r0, [r4, #12]      /* value buffer size: 4 bytes (one u32) */
    mov r0, #0
    str r0, [r4, #16]      /* req/resp length: 0 on send */
    str r0, [r4, #20]      /* value word -- firmware overwrites with
                             * the real bitmask on return */
    str r0, [r4, #24]      /* end tag */

    mov r0, r4
    bl mbox_property_call
#ifdef DMA_UART_INIT_DIAG_FOR_REAL_HARDWARE
    mov r2, r0                       /* stash mbox status -- sched_diag_
                                       * puts/put_hex32 both take their
                                       * own argument in r0 but never
                                       * touch r2, see their own header
                                       * comments in context_switch.S */
    ldr r0, =dma_uart_init_diag_mbox_status
    bl sched_diag_puts
    mov r0, r2
    bl sched_diag_put_hex32
    ldr r0, =dma_uart_init_diag_nl
    bl sched_diag_puts
    bl dma_uart_init_diag_drain_wait
    cmp r2, #0
#else
    cmp r0, #0
#endif
    bne dma_uart_init_no_channel   /* mailbox call itself failed --
                                     * conservative: treat as "no
                                     * channel known safe", not "assume
                                     * anything is safe" */

    ldr r5, [r4, #20]      /* r5 = firmware's own available-channel
                             * bitmask, bit N = channel N safe to use */
#ifdef DMA_UART_INIT_DIAG_FOR_REAL_HARDWARE
    ldr r0, =dma_uart_init_diag_mask
    bl sched_diag_puts
    mov r0, r5
    bl sched_diag_put_hex32
    ldr r0, =dma_uart_init_diag_nl
    bl sched_diag_puts
    bl dma_uart_init_diag_drain_wait
#endif
    mov r6, #0             /* r6 = candidate channel, scan 0..15 */
dma_uart_init_scan:
    cmp r6, #16
    bge dma_uart_init_no_channel
    mov r0, #1
    mov r0, r0, lsl r6
    tst r5, r0
    bne dma_uart_init_found
    add r6, r6, #1
    b dma_uart_init_scan

dma_uart_init_found:
#ifdef DMA_UART_INIT_DIAG_FOR_REAL_HARDWARE
    ldr r0, =dma_uart_init_diag_chan
    bl sched_diag_puts
    mov r0, r6
    bl sched_diag_put_hex32
    ldr r0, =dma_uart_init_diag_nl
    bl sched_diag_puts
    bl dma_uart_init_diag_drain_wait
#endif

    ldr r1, =dma_uart_channel_val
    str r6, [r1]
    ldr r1, =dma_uart_channel_valid
    mov r0, #1
    str r0, [r1]

    ldr r1, =0x20007FF0   /* DMA global ENABLE register */
    ldr r0, [r1]
    mov r2, #1
    orr r0, r0, r2, lsl r6
    str r0, [r1]
    bl mem_barrier

#ifdef DMA_UART_INIT_DIAG_FOR_REAL_HARDWARE
    ldr r0, =dma_uart_init_diag_pre_enable_write
    bl sched_diag_puts

    /* TASK #357 real-HW follow-up (2026-10-17), second attempt: the
     * ENABLE write above is a read-modify-write of a SHARED register
     * every DMA channel's bit lives in -- diagnostic print placed
     * AFTER it (not before) specifically to tell whether a hang is
     * already happening here (shared ENABLE register access itself
     * stalling the bus) versus only at the per-channel CS register
     * below. The first real-HW trial's own comment (see this file's
     * header) says the old hardcoded-channel-5 code hung "right at
     * the channel-5 RESET write" specifically -- this print, if it's
     * the LAST thing seen before a hang, confirms that same exact
     * instruction is still the culprit even with a firmware-selected
     * channel, which would mean the hang is not about WHICH channel
     * was picked at all. */
    ldr r0, =dma_uart_init_diag_nl
    bl sched_diag_puts
    bl dma_uart_init_diag_drain_wait
#endif

    ldr r4, =0x20007000   /* DMA_BASE -- channel r6's CS register is
                            * DMA_BASE + r6*0x100, same uniform layout
                            * every channel (0-15) shares on this SoC */
    add r4, r4, r6, lsl #8
    mov r0, #0x80000000   /* RESET (bit 31) */
    str r0, [r4]
    bl mem_barrier

#ifdef DMA_UART_INIT_DIAG_FOR_REAL_HARDWARE
    ldr r0, =dma_uart_init_diag_post_reset_write
    bl sched_diag_puts
    ldr r0, =dma_uart_init_diag_nl
    bl sched_diag_puts
    bl dma_uart_init_diag_drain_wait
#endif

    mov r0, #0
    mov r1, #0
    pop {r4, r5, r6, lr}
    bx lr

dma_uart_init_no_channel:
#ifdef DMA_UART_INIT_DIAG_FOR_REAL_HARDWARE
    ldr r0, =dma_uart_init_diag_no_channel
    bl sched_diag_puts
    bl dma_uart_init_diag_drain_wait
#endif
    mov r0, #1
    mov r1, #0
    pop {r4, r5, r6, lr}
    bx lr

#ifdef DMA_UART_INIT_DIAG_FOR_REAL_HARDWARE
/* void dma_uart_init_diag_drain_wait() -- forces the UART TX ring
 * (boot/uart_tx_ring_state.S) empty before this function's own debug
 * prints continue, debugging-only helper added alongside this round's
 * diagnostics. Needed because the ring's only idle-time drain pump
 * (uart_tx_ring_drain_only, called from timer_tick_dispatch every
 * tick) isn't running yet this early in boot -- the scheduler/timer
 * hasn't started. Without this, each sched_diag_puts call only
 * drains up to 16 bytes itself (the PL011 FIFO depth), so printing
 * several diagnostic lines back-to-back with no intervening tick
 * reliably overflows the ring's 64-byte capacity and SILENTLY drops
 * everything past it -- confirmed live this round: every one of 3
 * real-HW boot attempts cut off at the exact identical byte, deep
 * inside the very first diagnostic string, well before any DMA
 * register was even touched.
 *
 * Bounded by REAL ELAPSED TIME (TIMER_CLO, microseconds), not by a
 * fixed iteration count -- a fast busy-spin loop with no per-
 * iteration delay can execute tens of thousands of iterations in
 * far less wall-clock time than the physical UART needs to drain
 * even one FIFO's worth of bytes at this boot's measured ~4573 baud
 * (~1.75ms/byte, ~112ms worst case for a full 64-byte ring) -- an
 * iteration-count bound would appear to "wait" while actually giving
 * up almost immediately. 200ms is comfortably over that worst case.
 *
 * GATED by DMA_UART_INIT_DIAG_FOR_REAL_HARDWARE (undefined by default
 * -- see build.sh's own DMA_UART_STATE_CFLAGS passthrough), NOT a
 * runtime flag: the first version of this diagnostic was unconditional
 * and broke the normal QEMU regression (phase4_milestone.py went from
 * a few seconds to 3m42s with 2 spurious FAILUREs) because dma_uart_
 * init() itself is called unconditionally every boot regardless of
 * UART_DMA_ADOPT_FOR_REAL_HARDWARE (see kernel_main.vani's own call
 * site) -- this real-time wait must never run outside an explicit,
 * deliberately-built real-HW debug image. */
.global dma_uart_init_diag_drain_wait
dma_uart_init_diag_drain_wait:
    /* r0-r3 included here deliberately, not just r4-r7 -- the nested
     * calls below (uart_tx_ring_drain_only especially: its own drain
     * loop uses r0-r3 freely as scratch, e.g. a direct `ldr r2,[r1]`
     * for the ring head, and never saves/restores them) clobber
     * whatever the CALLER had in r0-r3. Found live this round: dma_
     * uart_init stashes the mbox_property_call status in r2 right
     * before its first call to this function -- without this fix,
     * that status was silently overwritten by the ring head value
     * read inside uart_tx_ring_drain_only, so the `cmp r2,#0` check
     * immediately after returning here was comparing garbage, not
     * the real mailbox result. Looked EXACTLY like a successful call
     * with an all-zero channel mask on every single real-HW boot --
     * it wasn't; the real mask was never actually read. */
    push {r0, r1, r2, r3, r4, r5, r6, r7, lr}
    ldr r7, =0x20003004    /* TIMER_CLO -- free-running microsecond
                             * counter, same register this project's
                             * own BOOT DIAG checkpoints already read */
    ldr r6, [r7]            /* r6 = start time */
dma_uart_init_diag_drain_wait_loop:
    bl uart_tx_ring_drain_only
    bl uart_tx_ring_is_empty
    cmp r0, #1
    beq dma_uart_init_diag_drain_wait_done   /* ring empty -- done early */
    ldr r4, [r7]
    sub r4, r4, r6          /* elapsed (unsigned sub handles wrap) */
    ldr r5, =200000         /* 200ms bound */
    cmp r4, r5
    bls dma_uart_init_diag_drain_wait_loop
dma_uart_init_diag_drain_wait_done:
    pop {r0, r1, r2, r3, r4, r5, r6, r7, lr}
    bx lr

.section ".rodata"
dma_uart_init_diag_mbox_status: .asciz "DMA INIT DIAG: mbox status=0x"
dma_uart_init_diag_mask:         .asciz "DMA INIT DIAG: firmware channel mask=0x"
dma_uart_init_diag_chan:         .asciz "DMA INIT DIAG: selected channel=0x"
dma_uart_init_diag_pre_enable_write: .asciz "DMA INIT DIAG: ENABLE register write done"
dma_uart_init_diag_post_reset_write: .asciz "DMA INIT DIAG: CS RESET write done"
dma_uart_init_diag_no_channel:    .asciz "DMA INIT DIAG: no firmware-safe channel, staying on PIO\n"
dma_uart_init_diag_nl:            .asciz "\n"
.section ".text"
#endif

/* dma_uart_tx_start(buf_ptr: u32, len: u32) -> u32 -- r0=buf_ptr,
 * r1=len on entry. Populates the control block and starts the
 * dynamically-selected DMA channel (see dma_uart_init's own header
 * comment -- TASK #357 real-HW follow-up, no longer always channel 5)
 * transferring len bytes from buf_ptr to the UART0 DR register,
 * DREQ-paced (PERMAP=12, UART TX). Returns 0 on success, 1 if len==0
 * (refuses to touch hardware for a no-op transfer rather than starting
 * a zero-length DMA whose behavior the datasheet doesn't document), 2
 * if the selected channel is already busy with a PRIOR transfer, 3 if
 * dma_uart_init never found a firmware-safe channel at all (dma_uart_
 * channel_valid == 0 -- no DMA register touched in that case).
 *
 * Concurrency note, added after direct review: dma_uart_cb and the
 * selected channel are single, unlocked, shared global state -- this driver is
 * single-channel, single-in-flight-transfer-at-a-time BY DESIGN, not
 * an accident. Every current call site (the boot-time self-tests) is
 * single-threaded, sequential, pre-scheduler, so there is provably
 * zero concurrency risk TODAY -- but two callers racing this function
 * (e.g. two tasks, or a task and this project's own established
 * "second context" pattern of a real interrupt handler) would corrupt
 * the shared CB (one caller's SOURCE_AD combined with another's
 * TXFR_LEN, etc.), producing an unpredictable, potentially out-of-
 * range DMA transfer -- exactly the class of bug this project already
 * found and fixed once for the UART TX ring buffer (boot/uart_tx_
 * ring_state.S's own header comment has the full history). This busy
 * check is a real, load-bearing guard against that, not just
 * documentation -- if this driver is ever exposed to multiple task
 * callers, callers must still serialize among THEMSELVES (a mutex or
 * equivalent) since this check-then-act is not itself atomic against
 * a genuine preemption between the check and the CB write below; it
 * only prevents the CURRENT bug class (silent corruption with no
 * error), not a true multi-caller race, which is out of scope until
 * this driver actually has more than one caller.
 *
 * Caller's own responsibility: buf_ptr must stay valid and unmodified
 * until dma_uart_tx_busy() reports done -- exactly the same contract
 * as any other DMA-driven transfer, no different from this project's
 * own SD driver's own PIO buffer lifetime rules. */
.global dma_uart_tx_start
dma_uart_tx_start:
    push {r4, r5, r6, lr}
    mov r4, r0            /* r4 = buf_ptr */
    mov r5, r1            /* r5 = len */

    // TASK #357 real-HW follow-up: refuse up front if dma_uart_init
    // never found a firmware-safe channel -- same reasoning as dma_
    // uart_tx_busy's own matching guard (see its header comment).
    // Checked here too, not just relied on via that call below, so
    // this function is self-contained-safe regardless of call order.
    ldr r6, =dma_uart_channel_valid
    ldr r6, [r6]
    cmp r6, #0
    beq dma_uart_tx_start_no_channel

    bl dma_uart_tx_busy
    cmp r0, #0
    bne dma_uart_tx_start_busy

    cmp r5, #0
    beq dma_uart_tx_start_noop

    bl mem_barrier         /* every byte in [buf_ptr, buf_ptr+len) must
                             * genuinely be in RAM before the DMA engine
                             * (a separate bus master) starts reading it. */

    ldr r1, =dma_uart_cb
    ldr r0, =0x000C0148    /* TI: WAIT_RESP|DEST_DREQ|SRC_INC|PERMAP=12 */
    str r0, [r1, #0]
    str r4, [r1, #4]       /* SOURCE_AD = buf_ptr */
    ldr r0, =0x20201000    /* UART0 DR -- DEST_AD, fixed (DEST_INC=0) */
    str r0, [r1, #8]
    str r5, [r1, #12]      /* TXFR_LEN = len (bytes) */
    mov r0, #0
    str r0, [r1, #16]      /* STRIDE */
    str r0, [r1, #20]      /* NEXTCONBK = 0 */
    str r0, [r1, #24]
    str r0, [r1, #28]
    bl mem_barrier

    ldr r6, =dma_uart_channel_val   /* TASK #357 real-HW follow-up:
                                      * dynamically-selected channel,
                                      * not the old hardcoded 5 -- see
                                      * dma_uart_init's own header */
    ldr r6, [r6]
    ldr r4, =0x20007000    /* DMA_BASE; channel's own CS/CONBLK_AD base
                             * is DMA_BASE + channel*0x100 */
    add r4, r4, r6, lsl #8
    ldr r0, =dma_uart_cb
    str r0, [r4, #4]       /* CONBLK_AD */
    bl mem_barrier
    mov r0, #1             /* ACTIVE */
    str r0, [r4, #0]       /* CS */
    bl mem_barrier

    mov r0, #0
    pop {r4, r5, r6, lr}
    bx lr

dma_uart_tx_start_noop:
    mov r0, #1
    pop {r4, r5, r6, lr}
    bx lr

dma_uart_tx_start_busy:
    mov r0, #2
    pop {r4, r5, r6, lr}
    bx lr

dma_uart_tx_start_no_channel:
    mov r0, #3
    pop {r4, r5, r6, lr}
    bx lr

/* dma_ram_copy_test(src, dst, count) -> u32 -- diagnostic only, added
 * 2026-09-27 specifically to isolate a real bug in this file's own CB/
 * CS mechanics from a QEMU DMA-to-peripheral modeling limitation: the
 * first dma_uart_tx_self_test real-HW/QEMU attempt showed ZERO bytes
 * (not even one garbled byte) reaching the UART's own captured output,
 * with busy-poll iterations=0 -- ambiguous between "QEMU's own DMA
 * model can't reach MMIO peripherals" (this project's own established
 * pattern for SDHOST/GPIO-pull) and "this driver's own CB setup is
 * wrong and the transfer never really ran". A plain, un-paced (PERMAP
 * =0, matching the datasheet's own "continuous un-paced transfer")
 * RAM-to-RAM copy through the exact same channel/CB/CS code path
 * isolates the question: if THIS works under QEMU (confirmed
 * separately: QEMU's own bcm2835-dma.c model does perform real
 * memory-to-memory transfers), the CB/CS mechanics are proven sound
 * and the earlier zero-bytes result is a QEMU peripheral-modeling gap,
 * not a driver bug -- same "don't waste a real-HW round-trip on your
 * own uncaught bug" discipline this whole session has already paid
 * for once, applied here before it costs anything at all this time.
 *
 * TASK #357 real-HW follow-up (2026-10-17): returns 0 on success, 1 if
 * dma_uart_init never found a firmware-safe channel (previously always
 * returned 0 unconditionally, back when the channel was hardcoded and
 * this function had no failure path at all). */
.global dma_ram_copy_test
dma_ram_copy_test:
    push {r4, r5, r6, lr}
    mov r4, r0             /* src */
    mov r5, r1             /* dst */
    mov r6, r2             /* count */

    bl mem_barrier

    ldr r1, =dma_uart_cb
    mov r0, #0x100          /* TI: SRC_INC only, PERMAP=0 (un-paced) --
                              * DEST_INC set below via orr */
    orr r0, r0, #0x10       /* DEST_INC */
    str r0, [r1, #0]
    str r4, [r1, #4]        /* SOURCE_AD */
    str r5, [r1, #8]        /* DEST_AD */
    str r6, [r1, #12]       /* TXFR_LEN */
    mov r0, #0
    str r0, [r1, #16]
    str r0, [r1, #20]
    str r0, [r1, #24]
    str r0, [r1, #28]
    bl mem_barrier

    // TASK #357 real-HW follow-up: refuse if dma_uart_init never found
    // a firmware-safe channel -- same guard as dma_uart_tx_start/_busy
    // (see dma_uart_init's own header comment). The CB writes above are
    // harmless RAM-only state with no hardware side effect yet; nothing
    // has actually started a transfer at this point.
    ldr r4, =dma_uart_channel_valid
    ldr r4, [r4]
    cmp r4, #0
    beq dma_ram_copy_test_no_channel

    ldr r4, =dma_uart_channel_val   /* TASK #357 real-HW follow-up:
                                      * dynamically-selected channel --
                                      * src (this function's own r4) is
                                      * already consumed above, safe to
                                      * reuse here */
    ldr r4, [r4]
    ldr r0, =0x20007000
    add r4, r0, r4, lsl #8
    ldr r0, =dma_uart_cb
    str r0, [r4, #4]
    bl mem_barrier
    mov r0, #1
    str r0, [r4, #0]
    bl mem_barrier

    mov r0, #0
    pop {r4, r5, r6, lr}
    bx lr

dma_ram_copy_test_no_channel:
    mov r0, #1
    pop {r4, r5, r6, lr}
    bx lr

/* dma_uart_tx_busy() -> u32 -- 1 if the dynamically-selected channel's
 * own transfer is still in flight (CS.ACTIVE still set), 0 once it has
 * completed. ACTIVE auto-clears at the end of the transfer described
 * by the current CB (datasheet's own CS register description) --
 * reliable as a direct completion signal precisely because NEXTCONBK
 * is always 0 here (single CB, never chained), so "the current CB"
 * and "the whole transfer" are the same thing.
 *
 * TASK #357 real-HW follow-up: explicitly reports "not busy" (0)
 * without touching any MMIO address at all if dma_uart_init never
 * found a safe channel (dma_uart_channel_valid still 0) -- every real
 * caller already gates on dma_uart_init's own return status first
 * (uart_puts via uart_dma_ready, both self-tests directly), so this
 * should never actually trigger, but reading dma_uart_channel_val's
 * own meaningless-until-valid default (0, a legitimate channel number)
 * as if it were a real selection instead would be a real, if currently
 * unreachable, correctness gap -- silently driving channel 0 without
 * it ever having been confirmed firmware-safe. */
.global dma_uart_tx_busy
dma_uart_tx_busy:
    push {r4, lr}
    ldr r1, =dma_uart_channel_valid
    ldr r4, [r1]
    cmp r4, #0
    moveq r0, #0
    beq dma_uart_tx_busy_done
    ldr r1, =dma_uart_channel_val
    ldr r4, [r1]
    ldr r1, =0x20007000    /* DMA_BASE */
    add r1, r1, r4, lsl #8
    ldr r4, [r1]           /* mem_barrier (below) unconditionally
                             * zeroes r0/r1 on return -- the loaded CS
                             * value must survive in a register it
                             * doesn't touch, not r0. */
    bl mem_barrier
    and r0, r4, #1
dma_uart_tx_busy_done:
    pop {r4, lr}
    bx lr

.global uart_dma_ready_set
uart_dma_ready_set:
    ldr r1, =uart_dma_ready
    str r0, [r1]
    mov r0, #0
    mov r1, #0     /* round-71-class bug swept here (2026-10-17): this
                     * is declared `-> i64` in kernel_main.vani (real
                     * r0:r1 AAPCS pair) but never set r1 -- every
                     * caller today discards the result (`let _ = ...`)
                     * so it was benign, same shape as the other fixes
                     * this file's own header comment documents, fixed
                     * on sight per this project's own sweep-sibling-
                     * functions convention rather than left for a
                     * future caller to trip over. */
    bx lr

.global uart_dma_ready_get
uart_dma_ready_get:
    ldr r0, =uart_dma_ready
    ldr r0, [r0]
    bx lr
