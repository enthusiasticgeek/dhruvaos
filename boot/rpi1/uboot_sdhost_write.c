/* 28th SD round (2026-09-25): literal C transliteration of real U-Boot's
 * own working drivers/mmc/bcm2835_sdhost.c write-path algorithm (the
 * relevant subset of bcm2835_send_command, bcm2835_finish_command,
 * bcm2835_transfer_block_pio, bcm2835_transfer_pio, and
 * bcm2835_wait_transfer_complete), fetched from a real upstream clone
 * and independently confirmed via an actual real-HW write+read at
 * this exact board and card (24th SD round, docs/TODO.md) -- this is
 * NOT a guess at what U-Boot does, every register write, poll
 * condition, FSM value, and threshold below is copied line-for-line
 * from that source. Uses the same raw SDHOST MMIO addresses (base
 * 0x20202000) this project's own hand-written ARM asm driver
 * (boot/sdcard_state.S) already targets -- confirmed via the 24th
 * round's real U-Boot boot log to be the SAME physical peripheral
 * DhruvaOS itself drives (bcm2835-rpi-b's own device tree enables
 * &sdhost, not &sdhci, for this exact board's SD slot).
 *
 * WHY THIS EXISTS: three real, well-reasoned fixes derived from
 * comparing THIS SAME reference source against DhruvaOS's own
 * hand-written asm driver (burst-write restructuring, 25th/26th
 * round; SDHCFG_DATA_IRPT_EN removal, 27th round) each matched the
 * reference exactly and STILL failed to clear the real-HW write
 * wedge. Register-level diffing has been exhausted without a fix
 * landing. This function is a different kind of test: instead of
 * porting one more finding INTO the asm driver, it runs U-Boot's
 * actual, unmodified control flow -- written fresh here as C, not
 * reasoned about and reimplemented -- directly inside DhruvaOS's own
 * boot/runtime environment. Two possible outcomes, both genuinely
 * informative:
 *   - If this STILL wedges: the bug is not in write-path logic at
 *     all (this function's logic is, as close as C vs. real U-Boot
 *     source allows, identical to a proven-working reference) -- it
 *     is something about DhruvaOS's own surrounding state (an earlier
 *     register write, real hardware timing, memory layout) that no
 *     amount of further register-level porting can fix.
 *   - If this WORKS: there is still a real, uncaught gap in the
 *     hand-written asm driver, findable by diffing its exact
 *     behavior against this file line by line.
 *
 * Called ONLY from the existing 8-block real-HW diagnostic sweep
 * (block_num 2100-2107 -- see kernel_main.vani's sdhost_write_block_
 * once, use_write_diag gate). The production write path (every other
 * block, DharaFS's entire real write traffic) is completely
 * untouched by this file -- if this experimental path has any
 * lingering issue of its own, it cannot affect real data.
 *
 * Deliberately self-contained: no shared headers, no calls back into
 * vani-generated code or the existing asm driver, raw volatile MMIO
 * only -- same reasoning as boot/rpi1/runtime_stubs.c's own raw UART
 * helpers (this needs to work as a clean, independent implementation,
 * not one that could accidentally share a bug with what it's testing
 * against). */

#define SDCMD_ADDR   0x20202000u
#define SDARG_ADDR   0x20202004u
#define SDHSTS_ADDR  0x20202020u
#define SDEDM_ADDR   0x20202034u
#define SDHBCT_ADDR  0x2020203Cu
#define SDHBLC_ADDR  0x20202050u
#define SDDATA_ADDR  0x20202040u
#define TIMER_CLO_ADDR 0x20003004u

#define SDCMD_NEW_FLAG   0x8000u
#define SDCMD_FAIL_FLAG  0x4000u
#define SDCMD_WRITE_CMD  0x80u
#define SDCMD_CMD_MASK   0x3fu

/* SDHSTS_ERROR_MASK = CMD_TIME_OUT(0x40) | CRC7_ERROR(0x10) |
 * CRC16_ERROR(0x20) | REW_TIME_OUT(0x80) | FIFO_ERROR(0x08), copied
 * from bcm2835_sdhost.c's own #define -- confirmed identical to the
 * 0xF8 mask DhruvaOS's own asm/vani driver already uses. */
#define SDHSTS_ERROR_MASK 0xF8u

#define SDEDM_FSM_MASK        0xFu
#define SDEDM_FSM_IDENTMODE   0x0u
#define SDEDM_FSM_DATAMODE    0x1u
#define SDEDM_FSM_READDATA    0x2u
#define SDEDM_FSM_READWAIT    0x4u
#define SDEDM_FSM_WRITESTART1 0xAu
#define SDEDM_FSM_FORCE_DATA_MODE_BIT (1u << 19)

#define SDDATA_FIFO_WORDS     16
#define SDDATA_FIFO_PIO_BURST 8

/* Real, wall-clock timeout (matches U-Boot's own get_timer(0)/ms
 * bound, and this project's own already-shipped timer-based fix for
 * the existing driver, 18th SD round) -- TIMER_CLO is the BCM2835
 * system timer's free-running 1MHz counter, already used elsewhere
 * in this project for genuine scheduling decisions. */
#define TIMEOUT_US 1000000u

static inline unsigned int mmio_r(unsigned int addr) {
    return *(volatile unsigned int *)(unsigned long)addr;
}
static inline void mmio_w(unsigned int addr, unsigned int val) {
    *(volatile unsigned int *)(unsigned long)addr = val;
}

static unsigned int now_us(void) {
    return mmio_r(TIMER_CLO_ADDR);
}

/* Unsigned subtraction wraps correctly even across a TIMER_CLO
 * rollover -- same idiom this project's own vani-level timer code
 * already relies on elsewhere. */
static int timed_out(unsigned int t0, unsigned int budget_us) {
    unsigned int now = now_us();
    return (now - t0) >= budget_us;
}

/* Raw MMIO UART output, same PL011 register addresses/protocol as
 * boot/rpi1/runtime_stubs.c's own dhruva_oom_puts -- deliberately not
 * shared code, see this file's own header comment. */
static void u_putc(char c) {
    volatile unsigned int *fr = (volatile unsigned int *)0x20201018;
    volatile unsigned int *dr = (volatile unsigned int *)0x20201000;
    while ((*fr) & 0x20) {
        /* wait while TX FIFO full (FR bit 5) */
    }
    *dr = (unsigned int)(unsigned char)c;
}

static void u_puts(const char *s) {
    while (*s != '\0') {
        u_putc(*s);
        s = s + 1;
    }
}

static void u_hex32(unsigned int v) {
    static const char hexd[16] = "0123456789ABCDEF";
    int i;
    for (i = 7; i >= 0; i = i - 1) {
        u_putc(hexd[(v >> (i * 4)) & 0xF]);
    }
}

/* long long / void* signature to match vani's own extern "C" FFI
 * conventions exactly -- see runtime_stubs.c's own dhruva_fault_
 * inject_alloc_arm comment for the AAPCS register-pairing pitfall a
 * plain `long` parameter/return would reintroduce here. buf_ptr is a
 * raw pointer to 128 sequential 32-bit words (512 bytes), the same
 * "mut ref i64 used as an opaque address, not 8-byte elements"
 * convention this project's own asm fill loop already relies on
 * (boot/sdcard_state.S's own sdhost_fill_fifo_from_buffer_impl reads
 * with `ldr r3, [r0], #4` -- 4-byte stride, not 8). block_addr is
 * already-computed CMD24 argument (sdhost_card_addr's return value),
 * matching what kernel_main.vani's own sdhost_write_block_once
 * already passes to SDARG. Return convention mirrors sdhost_write_
 * block_once's own: 0=success, 1=command phase timed out/never
 * completed, 2=PIO/wait_transfer_complete wedge, 3=SDHSTS error bits
 * set after completion, 4=CMD24 FAIL_FLAG. */
long long uboot_style_sdhost_write_block(void *buf_ptr, long long block_addr) {
    unsigned int *buf = (unsigned int *)buf_ptr;
    unsigned int addr = (unsigned int)block_addr;
    unsigned int sdcmd;
    unsigned int sdhsts;
    unsigned int t0;

    /* 34th SD round (2026-09-26): the pre-CMD24/post-CMD24/post-PIO/
     * write-SUCCESS prints that used to sit here were UNCONDITIONAL --
     * firing on every single write, not just failures. At ~87us/byte
     * on this project's polled/blocking UART (no DMA, no buffering --
     * u_putc's own busy-wait confirms it), the ~6 lines this function
     * used to print per successful write cost tens of milliseconds of
     * dead time, some of it sitting squarely between CMD24's command
     * phase completing and the PIO data phase starting -- exactly
     * where card-side timing expectations matter most. User's own
     * direct observation ("uart print can certainly impact timing
     * boot") -- removed entirely from the success path; every
     * genuinely anomalous condition below already had its own
     * conditional print and keeps it unchanged. */

    /* bcm2835_read_wait_sdcmd, called before issuing a new command. */
    t0 = now_us();
    while (mmio_r(SDCMD_ADDR) & SDCMD_NEW_FLAG) {
        if (timed_out(t0, TIMEOUT_US)) {
            u_puts("SD DIAG: uboot-port pre-CMD24 previous command never completed\n");
            return 1;
        }
    }

    /* bcm2835_send_command: "Clear any error flags" -- copied
     * verbatim, including only clearing when ERROR_MASK bits are
     * actually set. */
    sdhsts = mmio_r(SDHSTS_ADDR);
    if (sdhsts & SDHSTS_ERROR_MASK) {
        mmio_w(SDHSTS_ADDR, sdhsts);
    }

    /* bcm2835_prepare_data: SDHBCT/SDHBLC written BEFORE SDARG/SDCMD. */
    mmio_w(SDHBCT_ADDR, 512u);
    mmio_w(SDHBLC_ADDR, 1u);

    mmio_w(SDARG_ADDR, addr);
    sdcmd = (24u & SDCMD_CMD_MASK) | SDCMD_WRITE_CMD;
    mmio_w(SDCMD_ADDR, sdcmd | SDCMD_NEW_FLAG);

    /* bcm2835_finish_command: bcm2835_read_wait_sdcmd again, waiting
     * for the command phase itself to complete. */
    t0 = now_us();
    for (;;) {
        sdcmd = mmio_r(SDCMD_ADDR);
        if (!(sdcmd & SDCMD_NEW_FLAG)) {
            break;
        }
        if (timed_out(t0, TIMEOUT_US)) {
            u_puts("SD DIAG: uboot-port CMD24 command phase never completed\n");
            return 1;
        }
    }
    if (sdcmd & SDCMD_FAIL_FLAG) {
        sdhsts = mmio_r(SDHSTS_ADDR);
        mmio_w(SDHSTS_ADDR, SDHSTS_ERROR_MASK);
        u_puts("SD DIAG: uboot-port CMD24 FAIL_FLAG SDHSTS=0x");
        u_hex32(sdhsts);
        u_puts("\n");
        return 4;
    }

    /* bcm2835_transfer_block_pio (is_read = false), 128 words = one
     * 512-byte block -- burst_words = min(PIO_BURST, copy_words),
     * poll once per burst, only proceed once real room >= burst_words
     * (U-Boot's own real threshold-gate, not "any room at all"). A
     * bounded retry cap is added here (U-Boot's own real loop has
     * none -- it's allowed to spin forever, relying on the card's own
     * hardware timing) since this function must return control on
     * real hardware regardless of outcome. */
    {
        int copy_words = 128;
        long long room_wait_iters = 0;

        while (copy_words > 0) {
            unsigned int edm = mmio_r(SDEDM_ADDR);
            int fill = (int)((edm >> 4) & 0x1Fu);
            int room = SDDATA_FIFO_WORDS - fill;
            int burst_words = (SDDATA_FIFO_PIO_BURST < copy_words) ? SDDATA_FIFO_PIO_BURST : copy_words;
            int words;

            if (room < burst_words) {
                room_wait_iters = room_wait_iters + 1;
                if (room_wait_iters > 20000000LL) {
                    u_puts("SD DIAG: uboot-port PIO burst-room poll timed out SDEDM=0x");
                    u_hex32(edm);
                    u_puts("\n");
                    return 2;
                }
                continue;
            }

            words = room;
            if (words > copy_words) {
                words = copy_words;
            }
            copy_words = copy_words - words;

            while (words > 0) {
                mmio_w(SDDATA_ADDR, *buf);
                buf = buf + 1;
                words = words - 1;
            }
        }
    }

    /* bcm2835_transfer_pio's own post-transfer check. */
    sdhsts = mmio_r(SDHSTS_ADDR);
    if (sdhsts & (0x20u | 0x10u | 0x08u)) { /* CRC16 | CRC7 | FIFO_ERROR */
        u_puts("SD DIAG: uboot-port transfer error SDHSTS=0x");
        u_hex32(sdhsts);
        u_puts("\n");
        return 3;
    }
    if (sdhsts & (0x40u | 0x80u)) { /* CMD_TIME_OUT | REW_TIME_OUT */
        u_puts("SD DIAG: uboot-port transfer timeout error SDHSTS=0x");
        u_hex32(sdhsts);
        u_puts("\n");
        return 3;
    }

    /* bcm2835_wait_transfer_complete, verbatim -- including the
     * FORCE_DATA_MODE branch even though it does not trigger for
     * FSM=WRITEDATA (confirmed this same round: only READWAIT/
     * WRITESTART1/READDATA reach it), kept for fidelity to the real
     * source rather than dropped as "known not to matter here". */
    t0 = now_us();
    for (;;) {
        unsigned int edm = mmio_r(SDEDM_ADDR);
        unsigned int fsm = edm & SDEDM_FSM_MASK;

        if ((fsm == SDEDM_FSM_IDENTMODE) || (fsm == SDEDM_FSM_DATAMODE)) {
            break;
        }
        if ((fsm == SDEDM_FSM_READWAIT) || (fsm == SDEDM_FSM_WRITESTART1) ||
            (fsm == SDEDM_FSM_READDATA)) {
            mmio_w(SDEDM_ADDR, edm | SDEDM_FSM_FORCE_DATA_MODE_BIT);
            break;
        }
        if (timed_out(t0, TIMEOUT_US)) {
            u_puts("SD DIAG: uboot-port wait_transfer_complete timeout SDEDM=0x");
            u_hex32(edm);
            u_puts("\n");
            return 2;
        }
    }

    sdhsts = mmio_r(SDHSTS_ADDR) & SDHSTS_ERROR_MASK;
    mmio_w(SDHSTS_ADDR, sdhsts);
    if (sdhsts != 0) {
        u_puts("SD DIAG: uboot-port post-wait SDHSTS error=0x");
        u_hex32(sdhsts);
        u_puts("\n");
        return 3;
    }

    return 0;
}
