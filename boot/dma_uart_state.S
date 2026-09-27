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
 * QEMU note: unlike SDHOST (never documented, community reverse-
 * engineered) and GPIO pull resistors (confirmed via QEMU source to
 * be unimplemented), QEMU 10.0.13's own bcm2835-dma.c model (checked
 * directly) DOES perform real guest-physical-address data movement
 * (ldl_le_phys/stl_le_phys, which route through the full system bus
 * including MMIO-backed regions, not just RAM) -- meaning a transfer
 * targeting the UART0 DR address should genuinely reach the pl011
 * model and show up in captured serial output, unlike this project's
 * usual "untestable under QEMU" peripherals. QEMU's own DMA model does
 * NOT implement DREQ pacing at all (it always runs a CB to completion
 * at full speed) -- harmless for correctness (real hardware paces
 * itself; QEMU just doesn't need to), but means QEMU can never
 * exercise this driver's own DREQ-gated timing, only whether the
 * bytes arrive correctly and in order.
 *
 * DMA channel 5 chosen: arbitrary but deliberate -- this project uses
 * no DMA channel anywhere yet, so any channel is free, but channel 0
 * is the one channel occasionally referenced in bare-metal Pi
 * community writeups as touched transiently by GPU firmware before
 * the ARM core starts; channel 5 avoids that already-resolved-by-then
 * concern for zero cost. */

.section ".bss"
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

/* dma_uart_init() -- one-time setup, called once at boot before any
 * dma_uart_tx_start call. Resets DMA channel 5 (RESET bit, W1SC, self-
 * clearing per the datasheet's own CS register description) and sets
 * its bit in the global ENABLE register -- never assumed already
 * enabled by reset default, matching this project's own established
 * "no trust, validate everything" discipline for every other
 * peripheral's own power/enable state. */
.global dma_uart_init
dma_uart_init:
    push {r4, lr}

    ldr r1, =0x20007FF0   /* DMA global ENABLE register */
    ldr r0, [r1]
    orr r0, r0, #(1 << 5) /* channel 5 */
    str r0, [r1]
    bl mem_barrier

    ldr r4, =0x20007500   /* DMA channel 5 CS register */
    mov r0, #0x80000000   /* RESET (bit 31) */
    str r0, [r4]
    bl mem_barrier

    pop {r4, lr}
    bx lr

/* dma_uart_tx_start(buf_ptr: u32, len: u32) -> u32 -- r0=buf_ptr,
 * r1=len on entry. Populates the control block and starts DMA channel
 * 5 transferring len bytes from buf_ptr to the UART0 DR register,
 * DREQ-paced (PERMAP=12, UART TX). Returns 0 on success, 1 if len==0
 * (refuses to touch hardware for a no-op transfer rather than starting
 * a zero-length DMA whose behavior the datasheet doesn't document), 2
 * if channel 5 is already busy with a PRIOR transfer.
 *
 * Concurrency note, added after direct review: dma_uart_cb and channel
 * 5 are single, unlocked, shared global state -- this driver is
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
    push {r4, r5, lr}
    mov r4, r0            /* r4 = buf_ptr */
    mov r5, r1            /* r5 = len */

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

    ldr r4, =0x20007500    /* DMA channel 5 CS/CONBLK_AD base */
    ldr r0, =dma_uart_cb
    str r0, [r4, #4]       /* CONBLK_AD */
    bl mem_barrier
    mov r0, #1             /* ACTIVE */
    str r0, [r4, #0]       /* CS */
    bl mem_barrier

    mov r0, #0
    pop {r4, r5, lr}
    bx lr

dma_uart_tx_start_noop:
    mov r0, #1
    pop {r4, r5, lr}
    bx lr

dma_uart_tx_start_busy:
    mov r0, #2
    pop {r4, r5, lr}
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
 * for once, applied here before it costs anything at all this time. */
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

    ldr r4, =0x20007500
    ldr r0, =dma_uart_cb
    str r0, [r4, #4]
    bl mem_barrier
    mov r0, #1
    str r0, [r4, #0]
    bl mem_barrier

    mov r0, #0
    pop {r4, r5, r6, lr}
    bx lr

/* dma_uart_tx_busy() -> u32 -- 1 if channel 5's own transfer is still
 * in flight (CS.ACTIVE still set), 0 once it has completed. ACTIVE
 * auto-clears at the end of the transfer described by the current CB
 * (datasheet's own CS register description) -- reliable as a direct
 * completion signal precisely because NEXTCONBK is always 0 here
 * (single CB, never chained), so "the current CB" and "the whole
 * transfer" are the same thing. */
.global dma_uart_tx_busy
dma_uart_tx_busy:
    push {r4, lr}
    ldr r1, =0x20007500    /* DMA channel 5 CS register */
    ldr r4, [r1]           /* mem_barrier (below) unconditionally
                             * zeroes r0/r1 on return -- the loaded CS
                             * value must survive in a register it
                             * doesn't touch, not r0. */
    bl mem_barrier
    and r0, r4, #1
    pop {r4, lr}
    bx lr
