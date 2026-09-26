/* 34th SD round follow-up (2026-09-26): round 28's literal C port of
 * U-Boot's write algorithm (uboot_sdhost_write.c) proved the PIO loop
 * LOGIC matches U-Boot byte-for-byte, and still failed on real
 * hardware -- but it only ever replaces the write function itself; it
 * still runs on top of DhruvaOS's OWN hand-written bring-up sequence
 * (kernel_main.vani's sdhost_init_at_speed: CMD0/CMD8/ACMD41/CMD2/
 * CMD3/CMD9/CMD7/CMD16/ACMD6). That proves the write LOOP isn't the
 * bug, but never proved the BRING-UP leaves the card in the same
 * state U-Boot's own bring-up would. Five other real-HW hypotheses
 * (clock speed, power-supply undervoltage, USB dongles, a UART ring-
 * buffer race, and per-transfer CMD16 reissue) were each tested
 * directly and ruled out or fixed without resolving the CRC16(write)/
 * FIFO_ERROR(read) symptom -- see project memory for the full history.
 * User's own direct question ("if card was bad why uboot boots?")
 * correctly ruled out a hardware/card defect too (round 24's real
 * U-Boot test succeeded on this exact card/board).
 *
 * This extends round 28's own method to the ENTIRE bring-up chain,
 * not just the write loop: a literal, self-contained C port of real
 * U-Boot's mmc_go_idle/mmc_send_if_cond/sd_send_op_cond/mmc_startup
 * (drivers/mmc/mmc.c) and bcm2835_send_cmd/_send_command/_finish_
 * command (drivers/mmc/bcm2835_sdhost.c), run as ONE continuous,
 * independent sequence from CMD0 through CMD7, completely bypassing
 * DhruvaOS's own vani-level init. Notably includes real U-Boot's
 * top-level FSM-idle precondition check (bcm2835_send_cmd itself,
 * before ANY command) -- flagged during the 32nd round's systematic
 * comparison as a real divergence (DhruvaOS's own sdhost_cmd never
 * checks this) but never enforced as an actual gate until now, since
 * a diagnostic-only version showed zero occurrences under real-HW
 * testing at the time. Here it is a REAL, enforced precondition,
 * matching U-Boot's own behavior exactly (refuses to issue the
 * command at all if the FSM isn't already idle).
 *
 * If this ENTIRE port -- init through one write and one read -- still
 * fails the same way, that's decisive: the bug isn't anywhere in this
 * driver's own command sequencing at all, and the search needs to
 * move to something even more fundamental (MMU/cache/memory
 * attributes for the peripheral region, or genuinely something in
 * DhruvaOS's broader runtime environment U-Boot's own single-threaded
 * execution never exercises). If it succeeds, the bug is isolated to
 * something specific in DhruvaOS's own existing bring-up code, newly
 * findable by diffing this file's own real trace against it.
 *
 * Deliberately self-contained, matching uboot_sdhost_write.c's own
 * established discipline -- raw volatile MMIO only, no shared state
 * with the existing hand-written driver or vani-generated code. */

#define SDCMD_ADDR   0x20202000u
#define SDARG_ADDR   0x20202004u
#define SDTOUT_ADDR  0x20202008u
#define SDCDIV_ADDR  0x2020200Cu
#define SDRSP0_ADDR  0x20202010u
#define SDRSP1_ADDR  0x20202014u
#define SDRSP2_ADDR  0x20202018u
#define SDRSP3_ADDR  0x2020201Cu
#define SDHSTS_ADDR  0x20202020u
#define SDVDD_ADDR   0x20202030u
#define SDEDM_ADDR   0x20202034u
#define SDHCFG_ADDR  0x20202038u
#define SDHBCT_ADDR  0x2020203Cu
#define SDHBLC_ADDR  0x20202050u
#define SDDATA_ADDR  0x20202040u
#define TIMER_CLO_ADDR 0x20003004u
#define GPFSEL4_ADDR 0x20200210u
#define GPFSEL5_ADDR 0x20200214u
#define MBOX_STATUS_ADDR 0x2000B898u
#define MBOX_WRITE_ADDR  0x2000B8A0u
#define MBOX_READ_ADDR   0x2000B880u

#define SDCMD_NEW_FLAG   0x8000u
#define SDCMD_FAIL_FLAG  0x4000u
#define SDCMD_BUSYWAIT   0x800u
#define SDCMD_NO_RESPONSE 0x400u
#define SDCMD_LONG_RESPONSE 0x200u
#define SDCMD_WRITE_CMD  0x80u
#define SDCMD_READ_CMD   0x40u
#define SDCMD_CMD_MASK   0x3fu

#define SDHSTS_CLEAR_MASK 0x7F8u
#define SDHSTS_ERROR_MASK 0xF8u
#define SDHSTS_CRC7_ERROR 0x10u
#define SDHSTS_CMD_TIME_OUT 0x40u

#define SDEDM_FSM_MASK 0xFu
#define SDEDM_FSM_IDENTMODE 0x0u
#define SDEDM_FSM_DATAMODE  0x1u
#define SDEDM_FSM_READDATA  0x2u
#define SDEDM_FSM_READWAIT  0x4u
#define SDEDM_FSM_WRITESTART1 0xAu
#define SDEDM_FORCE_DATA_MODE_BIT (1u << 19)

#define SDDATA_FIFO_WORDS 16
#define SDDATA_FIFO_PIO_BURST 8

#define OCR_BUSY 0x80000000u
#define OCR_HCS  0x40000000u

#define TIMEOUT_US 1000000u
#define CMD_TIMEOUT_US 100000u

static inline unsigned int mmio_r(unsigned int addr) {
    return *(volatile unsigned int *)(unsigned long)addr;
}
static inline void mmio_w(unsigned int addr, unsigned int val) {
    *(volatile unsigned int *)(unsigned long)addr = val;
}
static unsigned int now_us(void) { return mmio_r(TIMER_CLO_ADDR); }
static int elapsed_at_least(unsigned int t0, unsigned int budget_us) {
    return (now_us() - t0) >= budget_us;
}
static void udelay_real(unsigned int us) {
    unsigned int t0 = now_us();
    while (!elapsed_at_least(t0, us)) { }
}

static void u_putc(char c) {
    volatile unsigned int *fr = (volatile unsigned int *)0x20201018;
    volatile unsigned int *dr = (volatile unsigned int *)0x20201000;
    while ((*fr) & 0x20) { }
    *dr = (unsigned int)(unsigned char)c;
}
static void u_puts(const char *s) {
    while (*s != '\0') { u_putc(*s); s = s + 1; }
}
static void u_hex32(unsigned int v) {
    static const char hexd[16] = "0123456789ABCDEF";
    int i;
    for (i = 7; i >= 0; i = i - 1) {
        u_putc(hexd[(v >> (i * 4)) & 0xF]);
    }
}

/* Real command/response state, mirroring struct mmc_cmd's relevant
 * fields only -- no data-phase members here, prepare_data is inlined
 * directly into uboot_style_send_cmd below since every caller in this
 * file either has no data phase or handles PIO itself afterward. */
struct cmd_result {
    unsigned int response[4];
    int err; /* 0 = ok, -1 = timeout/busy, -2 = FAIL_FLAG (real card/
              * controller error), -3 = FSM not idle (refused, never
              * even issued -- matches real U-Boot's own top-level
              * gate) */
};

/* bcm2835_send_cmd + bcm2835_send_command + bcm2835_finish_command,
 * combined into one real, faithful sequence (real U-Boot's own three-
 * function split exists for its own busy/data-phase state machine,
 * which this driver's single-block-only, no-DMA use never needs).
 * cmd_idx: 0-63 (already includes NO app-cmd handling -- caller issues
 * CMD55 itself first for ACMD*). resp_type: bit0=RSP_PRESENT,
 * bit1=RSP_136, bit2=RSP_BUSY (matches MMC_RSP_* shape closely enough
 * for this file's own needs, not the real bitfield encoding). data_sz/
 * blocks: nonzero only for a data-phase command (SDHBCT/SDHBLC),
 * matching bcm2835_prepare_data. is_write/is_read: SDCMD_WRITE_CMD/
 * READ_CMD. allow_crc7_tolerance: real U-Boot's own finish_command
 * quirk for SEND_OP_COND (a CRC7 error is expected/ignored for that
 * one specific command since some cards don't compute it correctly
 * pre-ready). */
static void uboot_style_send_cmd(unsigned int cmd_idx, unsigned int arg,
                                  int resp_present, int resp_136, int resp_busy,
                                  unsigned int data_blksz, unsigned int data_blocks,
                                  int is_write, int is_read,
                                  int allow_crc7_tolerance,
                                  struct cmd_result *out) {
    unsigned int edm, fsm, sdcmd, sdhsts, t0;
    int i;

    out->err = 0;
    out->response[0] = out->response[1] = out->response[2] = out->response[3] = 0;

    /* Real U-Boot's own top-level FSM-idle precondition
     * (bcm2835_send_cmd) -- refuses to issue ANY command unless the
     * controller's FSM is already IDENTMODE or DATAMODE. STOP_
     * TRANSMISSION (CMD12) is the one documented exception; this file
     * never issues it, so the check applies unconditionally here. */
    edm = mmio_r(SDEDM_ADDR);
    fsm = edm & SDEDM_FSM_MASK;
    if (fsm != SDEDM_FSM_IDENTMODE && fsm != SDEDM_FSM_DATAMODE) {
        u_puts("SD DIAG: uboot-full FSM NOT idle before cmd=");
        u_hex32(cmd_idx);
        u_puts(" SDEDM=0x");
        u_hex32(edm);
        u_puts("\n");
        out->err = -3;
        return;
    }

    /* bcm2835_send_command: wait for any PREVIOUS command's own
     * NEW_FLAG to clear first. */
    t0 = now_us();
    for (;;) {
        sdcmd = mmio_r(SDCMD_ADDR);
        if (!(sdcmd & SDCMD_NEW_FLAG)) break;
        if (elapsed_at_least(t0, CMD_TIMEOUT_US)) {
            u_puts("SD DIAG: uboot-full previous command never completed before cmd=");
            u_hex32(cmd_idx);
            u_puts("\n");
            out->err = -1;
            return;
        }
    }

    sdhsts = mmio_r(SDHSTS_ADDR);
    if (sdhsts & SDHSTS_ERROR_MASK) {
        mmio_w(SDHSTS_ADDR, sdhsts);
    }

    if (data_blksz != 0) {
        mmio_w(SDHBCT_ADDR, data_blksz);
        mmio_w(SDHBLC_ADDR, data_blocks);
    }

    mmio_w(SDARG_ADDR, arg);

    sdcmd = cmd_idx & SDCMD_CMD_MASK;
    if (!resp_present) {
        sdcmd |= SDCMD_NO_RESPONSE;
    } else {
        if (resp_136) sdcmd |= SDCMD_LONG_RESPONSE;
        if (resp_busy) sdcmd |= SDCMD_BUSYWAIT;
    }
    if (is_write) sdcmd |= SDCMD_WRITE_CMD;
    if (is_read) sdcmd |= SDCMD_READ_CMD;

    mmio_w(SDCMD_ADDR, sdcmd | SDCMD_NEW_FLAG);

    /* bcm2835_finish_command: wait for THIS command's own NEW_FLAG to
     * clear. */
    t0 = now_us();
    for (;;) {
        sdcmd = mmio_r(SDCMD_ADDR);
        if (!(sdcmd & SDCMD_NEW_FLAG)) break;
        if (elapsed_at_least(t0, CMD_TIMEOUT_US)) {
            u_puts("SD DIAG: uboot-full command phase never completed cmd=");
            u_hex32(cmd_idx);
            u_puts("\n");
            out->err = -1;
            return;
        }
    }

    if (sdcmd & SDCMD_FAIL_FLAG) {
        sdhsts = mmio_r(SDHSTS_ADDR);
        mmio_w(SDHSTS_ADDR, SDHSTS_ERROR_MASK);
        if (allow_crc7_tolerance && (sdhsts & SDHSTS_CRC7_ERROR)) {
            /* real U-Boot's own SEND_OP_COND tolerance -- treat as a
             * genuine (if CRC-invalid) response, not a hard failure. */
        } else {
            u_puts("SD DIAG: uboot-full cmd=");
            u_hex32(cmd_idx);
            u_puts(" FAIL_FLAG SDHSTS=0x");
            u_hex32(sdhsts);
            u_puts("\n");
            out->err = -2;
            return;
        }
    }

    if (resp_present) {
        if (resp_136) {
            unsigned int r0 = mmio_r(SDRSP0_ADDR);
            unsigned int r1 = mmio_r(SDRSP1_ADDR);
            unsigned int r2 = mmio_r(SDRSP2_ADDR);
            unsigned int r3 = mmio_r(SDRSP3_ADDR);
            out->response[3] = r0;
            out->response[2] = r1;
            out->response[1] = r2;
            out->response[0] = r3;
        } else {
            out->response[0] = mmio_r(SDRSP0_ADDR);
        }
    }
    (void)i;
}

/* bcm2835_reset_internal + bcm2835_set_clock(ident speed), real port.
 * gpio mux (ALT0 on pins 48-53) matches DhruvaOS's own already-
 * verified-correct gpio_sdhost_alt_init bit patterns exactly -- see
 * kernel_main.vani's own gpio_sdhost_alt_init for the byte-for-byte
 * confirmation, reused here unchanged rather than re-derived. */
static void uboot_style_gpio_mux(void) {
    unsigned int r4 = mmio_r(GPFSEL4_ADDR);
    mmio_w(GPFSEL4_ADDR, (r4 & 0xC0FFFFFFu) | 0x24000000u);
    unsigned int r5 = mmio_r(GPFSEL5_ADDR);
    mmio_w(GPFSEL5_ADDR, (r5 & 0xFFFFF000u) | 0x00000924u);
}

static void uboot_style_reset_and_ident_clock(void) {
    unsigned int temp;

    uboot_style_gpio_mux();

    mmio_w(SDVDD_ADDR, 0);
    mmio_w(SDCMD_ADDR, 0);
    mmio_w(SDARG_ADDR, 0);
    mmio_w(SDTOUT_ADDR, 0xf00000u);
    mmio_w(SDCDIV_ADDR, 0);
    mmio_w(SDHSTS_ADDR, SDHSTS_CLEAR_MASK);
    mmio_w(SDHCFG_ADDR, 0);
    mmio_w(SDHBCT_ADDR, 0);
    mmio_w(SDHBLC_ADDR, 0);

    temp = mmio_r(SDEDM_ADDR);
    temp &= ~((0x1Fu << 14) | (0x1Fu << 9));
    temp |= (4u << 14) | (4u << 9);
    mmio_w(SDEDM_ADDR, temp);

    udelay_real(20000);
    mmio_w(SDVDD_ADDR, 1);
    udelay_real(20000);

    /* host->hcfg starts as just BUSY_IRPT_EN (bcm2835_add_host); the
     * real per-transfer SDHCFG value gets set later by whatever issues
     * the actual read/write (matching bcm2835_set_ios's own timing --
     * it runs on every mmc_set_ios call, not just once at reset). */
    mmio_w(SDHCFG_ADDR, 0x400u);

    /* Identification-speed SDCDIV: SDCDIV_MAX_CDIV (0x7ff), real
     * U-Boot's own bcm2835_set_clock(clock < 100000) branch. */
    mmio_w(SDCDIV_ADDR, 0x7ffu);
}

/* long long uboot_style_full_sequence_test(unsigned int rca_out_addr)
 * -- runs a complete, independent bring-up (CMD0 through CMD7) plus
 * one write and one read-back to/from block_addr, entirely bypassing
 * DhruvaOS's own vani-level init. Returns 0 on full success (bring-up
 * AND write AND read-back-matches), or a negative code identifying
 * which stage failed, for a real-HW log to distinguish directly:
 *   -1  CMD0 (GO_IDLE) failed
 *   -2  CMD8 (SEND_IF_COND) failed or didn't echo the check pattern
 *   -3  ACMD41 (SD_SEND_OP_COND) never reported ready (ocr busy bit)
 *   -4  CMD2 (ALL_SEND_CID) failed
 *   -5  CMD3 (SEND_RELATIVE_ADDR) failed
 *   -6  CMD9 (SEND_CSD) failed
 *   -7  CMD7 (SELECT_CARD) failed
 *   -8  write (via the existing round-28 C port) failed
 *   -9  read failed
 *  -10  read-back data mismatch
 * block_addr is a byte address (already block_num*512), matching
 * uboot_style_sdhost_write_block's own convention. */
extern long long uboot_style_sdhost_write_block(void *buf_ptr, long long block_addr);

long long uboot_style_full_sequence_test(unsigned int block_addr, void *write_buf, void *read_buf) {
    struct cmd_result r;
    unsigned int rca;
    unsigned int retry;
    long long wstatus;
    int is_4bit;

    uboot_style_reset_and_ident_clock();

    /* mmc_go_idle: CMD0, no response. */
    uboot_style_send_cmd(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -1;

    /* mmc_send_if_cond: CMD8, R7 (short response), arg = voltage
     * range bit | 0xAA check pattern. Real U-Boot uses
     * ((voltages & 0xff8000) != 0) << 8 | 0xaa -- this board's own
     * declared voltage range (MMC_VDD_32_33|MMC_VDD_33_34, bcm2835_
     * sdhost.c's own bcm2835_add_host) always sets that bit, so 0x1AA
     * unconditionally, matching DhruvaOS's own existing CMD8 arg. */
    uboot_style_send_cmd(8, 0x1AAu, 1, 0, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0 || (r.response[0] & 0xFFu) != 0xAAu) return -2;

    /* sd_send_op_cond: CMD55 (APP_CMD) then ACMD41, looped with a real
     * 1000-iteration/1ms-each timeout (matching real U-Boot exactly),
     * checking OCR_BUSY (bit31) for "card ready". HCS (bit30) set
     * since this driver only ever targets SD 2.0+ high-capacity cards
     * (matches DhruvaOS's own existing ACMD41 arg). */
    retry = 1000;
    for (;;) {
        uboot_style_send_cmd(55, 0, 1, 0, 0, 0, 0, 0, 0, 0, &r);
        if (r.err != 0) return -3;
        uboot_style_send_cmd(41, 0x00FF8000u | OCR_HCS, 1, 0, 0, 0, 0, 0, 0, 1, &r);
        if (r.err != 0 && r.err != -2) return -3;
        if (r.response[0] & OCR_BUSY) break;
        if (retry == 0) return -3;
        retry = retry - 1;
        udelay_real(1000);
    }

    /* mmc_startup: CMD2 (ALL_SEND_CID, R2/136-bit). */
    uboot_style_send_cmd(2, 0, 1, 1, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -4;

    /* CMD3 (SEND_RELATIVE_ADDR, R6 -- a short response here, real
     * bcm2835_sdhost treats it as a normal short response). rca comes
     * back in response[0] bits[31:16]. */
    uboot_style_send_cmd(3, 0, 1, 0, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -5;
    rca = (r.response[0] >> 16) & 0xFFFFu;

    /* CMD9 (SEND_CSD, R2/136-bit) -- read for real-sequence fidelity;
     * this file doesn't need the high-capacity bit itself since the
     * write/read helpers below already assume the card's real
     * addressing mode (byte vs block) matches what
     * uboot_style_sdhost_write_block/the existing production driver
     * already established works. */
    uboot_style_send_cmd(9, rca << 16, 1, 1, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -6;

    /* CMD7 (SELECT_CARD, R1b -- busy response). */
    uboot_style_send_cmd(7, rca << 16, 1, 0, 1, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -7;

    /* sd_get_capabilities (SCR via ACMD51) + sd_select_bus_width
     * (ACMD6), real U-Boot order, faithfully attempted this time --
     * this board's own real device tree (bcm2835-rpi-b.dts ->
     * bcm2835-rpi.dtsi) declares `&sdhost { bus-width = <4>; };`,
     * meaning real U-Boot's own successful round-24 test may genuinely
     * have run in 4-bit mode, not 1-bit -- a mode DhruvaOS's own
     * existing ACMD6 attempts have NEVER once succeeded at, in any
     * prior round. A previous version of this port skipped ACMD6
     * entirely on the reasoning that it "matches the actual working
     * (1-bit) configuration" -- that reasoning no longer holds now
     * that the real DT confirms 4-bit is the actually-declared,
     * intended capability for this exact board. is_4bit tracks
     * whether this fresh, independent attempt succeeds where every
     * prior DhruvaOS attempt has failed -- itself a real, informative
     * result either way. */
    {
        struct cmd_result rr;
        unsigned int scr_buf[2];
        unsigned int *sbuf = scr_buf;
        int copy_words, i;
        long long room_wait_iters;

        is_4bit = 0;
        scr_buf[0] = 0;
        scr_buf[1] = 0;

        uboot_style_send_cmd(55, rca << 16, 1, 0, 0, 0, 0, 0, 0, 0, &rr);
        if (rr.err == 0) {
            mmio_w(SDHCFG_ADDR, 0x418u);
            uboot_style_send_cmd(SDCMD_READ_CMD | 51, 0, 1, 0, 0, 8, 1, 0, 1, 0, &rr);
            if (rr.err == 0) {
                copy_words = 2;
                room_wait_iters = 0;
                while (copy_words > 0) {
                    unsigned int edm = mmio_r(SDEDM_ADDR);
                    int fill = (int)((edm >> 4) & 0x1Fu);
                    int burst_words = (SDDATA_FIFO_PIO_BURST < copy_words) ? SDDATA_FIFO_PIO_BURST : copy_words;
                    int words;
                    if (fill < burst_words) {
                        room_wait_iters = room_wait_iters + 1;
                        if (room_wait_iters > 20000000LL) break;
                        continue;
                    }
                    words = fill;
                    if (words > copy_words) words = copy_words;
                    copy_words = copy_words - words;
                    while (words > 0) {
                        *sbuf = mmio_r(SDDATA_ADDR);
                        sbuf = sbuf + 1;
                        words = words - 1;
                    }
                }
                /* Real SCR bit 18 (SD_DATA_4BIT), big-endian byte 1's
                 * bit 2 -- word0 as received is byte0<<24|byte1<<16|
                 * byte2<<8|byte3 in transmission order; the raw 32-bit
                 * register read here is that same big-endian value
                 * directly (matches this project's own established
                 * sd_scr_dump_and_check_4bit reconstruction). */
                if (scr_buf[0] & 0x00040000u) {
                    struct cmd_result r6;
                    uboot_style_send_cmd(55, rca << 16, 1, 0, 0, 0, 0, 0, 0, 0, &r6);
                    if (r6.err == 0) {
                        uboot_style_send_cmd(6, 2, 1, 0, 0, 0, 0, 0, 0, 0, &r6);
                        if (r6.err == 0) is_4bit = 1;
                    }
                }
            }
            {
                unsigned int t0 = now_us();
                for (;;) {
                    unsigned int edm = mmio_r(SDEDM_ADDR);
                    unsigned int fsm = edm & SDEDM_FSM_MASK;
                    if (fsm == SDEDM_FSM_IDENTMODE || fsm == SDEDM_FSM_DATAMODE) break;
                    if (fsm == SDEDM_FSM_READWAIT || fsm == SDEDM_FSM_WRITESTART1 || fsm == SDEDM_FSM_READDATA) {
                        mmio_w(SDEDM_ADDR, edm | SDEDM_FORCE_DATA_MODE_BIT);
                        break;
                    }
                    if (elapsed_at_least(t0, TIMEOUT_US)) break;
                }
            }
            mmio_w(SDHSTS_ADDR, mmio_r(SDHSTS_ADDR) & SDHSTS_ERROR_MASK);
        }
        u_puts("SD DIAG: uboot-full SCR=0x");
        u_hex32(scr_buf[0]);
        u_puts(" is_4bit=");
        u_hex32((unsigned int)is_4bit);
        u_puts("\n");
        (void)i;
    }

    /* Data-transfer clock + SDHCFG. WIDE_INT_BUS|SLOW_CARD|
     * BUSY_IRPT_EN for write, +DATA_IRPT_EN for read (round 25-30
     * findings), +WIDE_EXT_BUS if ACMD6 actually switched the card
     * above. SDCDIV for 1MHz (div=248 @ 250MHz core), matching the
     * 34th round's own already-verified conservative default -- this
     * file computes it the same way rather than querying the mailbox
     * again, since sdhost_get_core_clock_hz has already confirmed
     * 250000000 on this exact board this session. */
    mmio_w(SDCDIV_ADDR, 248u);
    mmio_w(SDTOUT_ADDR, 500000u);

    mmio_w(SDHCFG_ADDR, is_4bit ? 0x40Eu : 0x40Au);
    wstatus = uboot_style_sdhost_write_block(write_buf, (long long)block_addr);
    if (wstatus != 0) return -8;

    mmio_w(SDHCFG_ADDR, is_4bit ? 0x41Cu : 0x418u);
    {
        /* Real U-Boot's own bcm2835_transfer_block_pio(is_read=true),
         * inlined here rather than factored into a separate function
         * -- this file's only read caller, no benefit to splitting it
         * out the way write_block deserved its own reusable function
         * (round 28 already needed write reusable from the production
         * driver; read has no such existing caller). */
        struct cmd_result rr;
        unsigned int *rbuf = (unsigned int *)read_buf;
        int copy_words;
        long long room_wait_iters;
        unsigned int sdhsts2;

        uboot_style_send_cmd(SDCMD_READ_CMD | 17, block_addr, 1, 0, 0, 512, 1, 0, 1, 0, &rr);
        if (rr.err != 0) return -9;

        copy_words = 128;
        room_wait_iters = 0;
        while (copy_words > 0) {
            unsigned int edm = mmio_r(SDEDM_ADDR);
            int fill = (int)((edm >> 4) & 0x1Fu);
            int burst_words = (SDDATA_FIFO_PIO_BURST < copy_words) ? SDDATA_FIFO_PIO_BURST : copy_words;
            int words;
            if (fill < burst_words) {
                room_wait_iters = room_wait_iters + 1;
                if (room_wait_iters > 20000000LL) return -9;
                continue;
            }
            words = fill;
            if (words > copy_words) words = copy_words;
            copy_words = copy_words - words;
            while (words > 0) {
                *rbuf = mmio_r(SDDATA_ADDR);
                rbuf = rbuf + 1;
                words = words - 1;
            }
        }

        sdhsts2 = mmio_r(SDHSTS_ADDR);
        if (sdhsts2 & (0x20u | 0x10u | 0x08u | 0x40u | 0x80u)) return -9;

        {
            unsigned int t0 = now_us();
            for (;;) {
                unsigned int edm = mmio_r(SDEDM_ADDR);
                unsigned int fsm = edm & SDEDM_FSM_MASK;
                if (fsm == SDEDM_FSM_IDENTMODE || fsm == SDEDM_FSM_DATAMODE) break;
                if (fsm == SDEDM_FSM_READWAIT || fsm == SDEDM_FSM_WRITESTART1 || fsm == SDEDM_FSM_READDATA) {
                    mmio_w(SDEDM_ADDR, edm | SDEDM_FORCE_DATA_MODE_BIT);
                    break;
                }
                if (elapsed_at_least(t0, TIMEOUT_US)) return -9;
            }
        }

        sdhsts2 = mmio_r(SDHSTS_ADDR) & SDHSTS_ERROR_MASK;
        mmio_w(SDHSTS_ADDR, sdhsts2);
        if (sdhsts2 != 0) return -9;
    }

    {
        unsigned char *w = (unsigned char *)write_buf;
        unsigned char *rd = (unsigned char *)read_buf;
        int i;
        for (i = 0; i < 512; i = i + 1) {
            if (w[i] != rd[i]) return -10;
        }
    }

    return 0;
}
