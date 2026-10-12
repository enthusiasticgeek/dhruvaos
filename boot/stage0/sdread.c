/* Stage-0 A/B kernel-slot loader -- minimal, 1-bit-mode-only SD driver.
 * Read-only for kernel payload slots; the one exception is
 * stage0_sd_write_block, added in Phase 3, used ONLY to persist the
 * slot-state record's own updated attempt_count/generation/active_slot
 * back to its 512-byte block (9216/9217) -- never used for payload
 * data, which only the already-booted real kernel's `kernelupload`
 * ever writes.
 *
 * Derived from boot/rpi1/uboot_sdhost_full.c (deleted as dead code in
 * commit a388164 once the round-42 SD wedge investigation it served
 * closed; recovered via `git show a388164^:boot/rpi1/uboot_sdhost_full.c`
 * for this purpose) and boot/rpi1/uboot_sdhost_write.c (recovered via
 * `git show a388164^:boot/rpi1/uboot_sdhost_write.c`, write-path
 * reference only -- stage0_sd_write_block below reuses this file's own
 * stage0_send_cmd dispatcher instead of porting that file's own
 * special-purpose CMD24 sequence verbatim, for one consistent code
 * path instead of two different styles). Both are literal, self-
 * contained C ports of real U-Boot's own SD bring-up (drivers/mmc/
 * mmc.c, drivers/mmc/bcm2835_sdhost.c), proven against this exact
 * board in the round-34/28 real-HW investigations.
 *
 * Deliberately stripped down from the recovered bring-up file:
 *   - No CMD55+ACMD51 (SCR read) / ACMD6 (4-bit switch) negotiation.
 *     Stage-0 always stays in 1-bit mode -- the historically reliable
 *     mode across this project's entire 42-round SD saga; 4-bit mode is
 *     where every real write-side wedge this project ever hit lived,
 *     and stage-0's own write use (the slot-state block only, 1 block
 *     per boot) has nothing to gain from it.
 *   - No read-back/memcmp self-check -- that belonged to a one-shot
 *     bring-up TEST, not a loader. Stage-0's own checksum-verify-
 *     before-jump (stage0_main.c) is the real correctness gate for
 *     kernel payload data; the slot-state block protects itself with
 *     its own CRC32 (stage0_main.c's parse_slot_state).
 *   - Split into a one-time stage0_sd_init() (bring-up through CMD7
 *     SELECT_CARD) and a reusable stage0_sd_read_block() callable many
 *     times afterward (a multi-MB slot is thousands of blocks -- redoing
 *     the whole CMD0..CMD7 sequence per block would be both wrong and
 *     far too slow).
 *   - FIXED vs. the recovered file: that file always treated its
 *     block_addr parameter as a pre-converted byte address, with no
 *     code path that ever reads back ACMD41's OCR response to tell a
 *     byte-addressed (SDSC) card from a block-addressed (SDHC/SDXC)
 *     one -- a real gap, masked there only because that file's own
 *     caller happened to pass an already-correct address for whatever
 *     card was in use at the time. stage0_sd_init() now captures the
 *     OCR_HCS/CCS bit from the final ACMD41 response and
 *     stage0_sd_read_block() addresses accordingly, matching the
 *     production driver's own sdhost_card_addr (kernel_main.vani) --
 *     this is the one place stage-0 needed a real fix, not just a
 *     trim, during the port.
 */

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
/* FIXED vs. the recovered file: it defined these as 0x20200210/
 * 0x20200214 (off by 0x200 / 512 bytes) -- the real GPFSEL4/GPFSEL5
 * registers are 0x20200010/0x20200014 (confirmed against kernel_main.
 * vani's own GPFSEL4/GPFSEL5 constants). This silently muxed nothing
 * -- GPIO pins 48-53 were never actually switched to SDHOST's ALT0
 * function, which is the real root cause this entire port's QEMU
 * failure traced back to (confirmed by a register-readback diagnostic
 * during this port: GPFSEL4/5 read back as 0x0 after the "mux" write,
 * and SDCDIV/other SDHOST writes made after it were affected too). */
#define GPFSEL4_ADDR 0x20200010u
#define GPFSEL5_ADDR 0x20200014u

#define SDCMD_NEW_FLAG   0x8000u
#define SDCMD_FAIL_FLAG  0x4000u
#define SDCMD_BUSYWAIT   0x800u
#define SDCMD_NO_RESPONSE 0x400u
#define SDCMD_LONG_RESPONSE 0x200u
#define SDCMD_READ_CMD   0x40u
#define SDCMD_WRITE_CMD  0x80u
#define SDCMD_CMD_MASK   0x3fu

#define SDHSTS_CLEAR_MASK 0x7F8u
#define SDHSTS_ERROR_MASK 0xF8u
#define SDHSTS_CRC7_ERROR 0x10u

#define SDEDM_FSM_MASK 0xFu
#define SDEDM_FSM_IDENTMODE 0x0u
#define SDEDM_FSM_DATAMODE  0x1u
#define SDEDM_FSM_READDATA  0x2u
#define SDEDM_FSM_READWAIT  0x4u
#define SDEDM_FSM_WRITESTART1 0xAu
#define SDEDM_FORCE_DATA_MODE_BIT (1u << 19)

#define SDDATA_FIFO_PIO_BURST 8

#define OCR_BUSY 0x80000000u
#define OCR_HCS  0x40000000u

#define TIMEOUT_US 1000000u
#define CMD_TIMEOUT_US 100000u

/* Real DSB barrier (ARMv6 "mcr p15,0,r0,c7,c10,4"), matching
 * kernel_main.vani's own sd_mmio_read_u32/write_u32 exactly -- every
 * SD register access there is barrier-wrapped; a plain volatile
 * pointer dereference only orders accesses as the COMPILER sees them,
 * not actual bus completion order, which matters for real hardware
 * regardless of whether it also explains any QEMU-specific behavior. */
static inline void dsb_barrier(void) {
    __asm__ volatile ("mcr p15, 0, %0, c7, c10, 4" :: "r"(0) : "memory");
}
static inline unsigned int mmio_r(unsigned int addr) {
    unsigned int v = *(volatile unsigned int *)(unsigned long)addr;
    dsb_barrier();
    return v;
}
static inline void mmio_w(unsigned int addr, unsigned int val) {
    dsb_barrier();
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

void u_putc(char c) {
    volatile unsigned int *fr = (volatile unsigned int *)0x20201018;
    volatile unsigned int *dr = (volatile unsigned int *)0x20201000;
    while ((*fr) & 0x20) { }
    *dr = (unsigned int)(unsigned char)c;
}
void u_puts(const char *s) {
    while (*s != '\0') { u_putc(*s); s = s + 1; }
}
void u_hex32(unsigned int v) {
    static const char hexd[16] = "0123456789ABCDEF";
    int i;
    for (i = 7; i >= 0; i = i - 1) {
        u_putc(hexd[(v >> (i * 4)) & 0xF]);
    }
}

struct cmd_result {
    unsigned int response[4];
    int err; /* 0 ok, -1 timeout, -2 FAIL_FLAG, -3 FSM not idle */
};

static unsigned int s_rca;
static int s_is_sdhc;

/* bcm2835_send_cmd + _send_command + _finish_command, combined -- see
 * uboot_sdhost_full.c's own header comment for the full rationale.
 * allow_crc7_tolerance: real U-Boot's own finish_command quirk for
 * SEND_OP_COND (some cards don't compute CRC7 correctly pre-ready). */
static void stage0_send_cmd(unsigned int cmd_idx, unsigned int arg,
                             int resp_present, int resp_136, int resp_busy,
                             unsigned int data_blksz, unsigned int data_blocks,
                             int is_read, int is_write, int allow_crc7_tolerance,
                             int ignore_fail_flag,
                             struct cmd_result *out) {
    unsigned int edm, fsm, sdcmd, sdhsts, t0;

    out->err = 0;
    out->response[0] = out->response[1] = out->response[2] = out->response[3] = 0;

    edm = mmio_r(SDEDM_ADDR);
    fsm = edm & SDEDM_FSM_MASK;
    if (fsm != SDEDM_FSM_IDENTMODE && fsm != SDEDM_FSM_DATAMODE) {
        u_puts("stage0: FSM not idle before cmd=");
        u_hex32(cmd_idx);
        u_puts(" SDEDM=0x");
        u_hex32(edm);
        u_puts("\n");
        out->err = -3;
        return;
    }

    t0 = now_us();
    for (;;) {
        sdcmd = mmio_r(SDCMD_ADDR);
        if (!(sdcmd & SDCMD_NEW_FLAG)) break;
        if (elapsed_at_least(t0, CMD_TIMEOUT_US)) {
            u_puts("stage0: previous command never completed before cmd=");
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
    if (is_read) sdcmd |= SDCMD_READ_CMD;
    if (is_write) sdcmd |= SDCMD_WRITE_CMD;

    mmio_w(SDCMD_ADDR, sdcmd | SDCMD_NEW_FLAG);

    t0 = now_us();
    for (;;) {
        sdcmd = mmio_r(SDCMD_ADDR);
        if (!(sdcmd & SDCMD_NEW_FLAG)) break;
        if (elapsed_at_least(t0, CMD_TIMEOUT_US)) {
            u_puts("stage0: command phase never completed cmd=");
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
            /* expected/ignored, matches real U-Boot's own tolerance */
        } else if (ignore_fail_flag) {
            /* Matches kernel_main.vani's own sdhost_init_at_speed
             * exactly: CMD8 (SEND_IF_COND) is one of several early
             * identification-phase commands (CMD8/CMD55/ACMD41) whose
             * production check is sdhost_cmd_timed_out-only (NEW_FLAG,
             * used to fork SD-vs-MMC) -- it never looks at FAIL_FLAG
             * for these, reading RSP0 unconditionally instead. Kept
             * even after the real bug this port hit (a wrong GPFSEL4/
             * GPFSEL5 address, see stage0_reset_and_ident_clock's own
             * comment) was found and fixed, since this is a genuine,
             * deliberate match to the reference's real behavior, not
             * a workaround for that bug. */
        } else {
            u_puts("stage0: cmd=");
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
}

/* bcm2835_reset_internal + bcm2835_set_clock(ident speed). GPIO ALT0
 * mux values byte-for-byte confirmed against kernel_main.vani's own
 * gpio_sdhost_alt_init, reused unchanged. */
/* FIXED vs. the recovered file in two ways:
 *  1. GPFSEL4/GPFSEL5 addresses were wrong (0x20200210/0x20200214,
 *     off by 0x200) -- the real registers are 0x20200010/0x20200014
 *     (confirmed against kernel_main.vani's own GPFSEL4/GPFSEL5
 *     constants). This was the actual root cause of every CMD8/
 *     CMD55/ACMD41/CMD2 failure hit while porting this file: the GPIO
 *     mux write landed on the wrong register, pins 48-53 never
 *     switched to SDHOST's ALT0 function, and the controller's
 *     commands went nowhere -- confirmed directly via a register-
 *     readback diagnostic (GPFSEL4/5 read back as 0x0 after the "mux"
 *     write) before this fix, and a correct readback (0x24000000/
 *     0x924) after it, at which point CMD8 got a real RSP0=0x1AA and
 *     ACMD41 succeeded on its first iteration, matching production
 *     exactly.
 *  2. Separately (real but not the root cause): this function's own
 *     register-write ORDER now also matches kernel_main.vani's own
 *     sdhost_init_at_speed step-by-step, including the FIFO pre-clear
 *     drain the recovered file never had: GPIO mux -> EDM threshold
 *     fix -> settle delay -> SDVDD power cycle (off/delay/on/delay)
 *     -> FIFO pre-clear drain -> SDCDIV/SDTOUT/SDHBCT/SDHBLC ->
 *     SDHCFG=0. The recovered file's own order (verified correct for
 *     real hardware in round 34) write the same final register
 *     values either way; this reordering is a correctness-by-
 *     reference-match improvement, kept for fidelity to the proven
 *     reference, not because it was independently shown necessary. */
static void stage0_reset_and_ident_clock(void) {
    unsigned int temp;
    int fifo_preclear_iter;

    unsigned int r4 = mmio_r(GPFSEL4_ADDR);
    mmio_w(GPFSEL4_ADDR, (r4 & 0xC0FFFFFFu) | 0x24000000u);
    unsigned int r5 = mmio_r(GPFSEL5_ADDR);
    mmio_w(GPFSEL5_ADDR, (r5 & 0xFFFFF000u) | 0x00000924u);

    temp = mmio_r(SDEDM_ADDR);
    temp &= ~((0x1Fu << 14) | (0x1Fu << 9));
    temp |= (4u << 14) | (4u << 9);
    mmio_w(SDEDM_ADDR, temp);

    udelay_real(20000);

    mmio_w(SDVDD_ADDR, 0);
    udelay_real(20000);
    mmio_w(SDVDD_ADDR, 1);
    udelay_real(20000);

    fifo_preclear_iter = 0;
    while (fifo_preclear_iter < 1000) {
        unsigned int fill = (mmio_r(SDEDM_ADDR) >> 4) & 0x1Fu;
        if (fill == 0) break;
        (void)mmio_r(SDDATA_ADDR);
        fifo_preclear_iter = fifo_preclear_iter + 1;
    }

    mmio_w(SDCDIV_ADDR, 0x148u);
    mmio_w(SDTOUT_ADDR, 0xF00000u);
    mmio_w(SDHBCT_ADDR, 0);
    mmio_w(SDHBLC_ADDR, 0);
    mmio_w(SDHCFG_ADDR, 0);
}

#define MBOX_READ_ADDR   0x2000B880u
#define MBOX_STATUS_ADDR 0x2000B898u
#define MBOX_WRITE_ADDR  0x2000B8A0u
#define MBOX_FULL        0x80000000u
#define MBOX_EMPTY       0x40000000u

/* Task #308 Phase 6 (real-HW bring-up): FIXED vs. the original port --
 * this used to hardcode SDCDIV=248 (1MHz) assuming the core clock is
 * exactly 250MHz, which real round-15/215-217 of this project's own
 * SD-wedge saga already found to be unsafe: real BCM2835 silicon does
 * not guarantee that, and the production driver (kernel_main.vani's
 * sdhost_init_at_speed) queries the REAL core clock via a VideoCore
 * mailbox GET_CLOCK_RATE call instead, then computes a divisor from
 * the answer -- exactly the fix that closed task #217 ("reads now
 * succeed on all 8 blocks") on real hardware. Stage0 skipped this
 * during its original QEMU-only bring-up (QEMU's own bcm2835-sdhost
 * model tolerates a hardcoded divisor fine) and failed its very first
 * real-hardware CMD17 as a direct result -- same class of QEMU-vs-
 * real-silicon gap this project has hit before (see e.g. the UART
 * clock's own "assumed 3MHz" warning in docs/HARDWARE_IN_LOOP.md
 * §3.2). Ported here literally rather than re-derived, down to the
 * message buffer layout (boot/sdcard_state.S's own sdhost_get_core_
 * clock_hz, itself a straight port of the VideoCore property-tags
 * protocol every mailbox call on this SoC uses). Returns 0 if the
 * mailbox call times out or VideoCore reports failure -- 0 cannot be
 * a real CORE clock rate on this SoC, so callers treat it as
 * "query failed," not a literal answer. */
static unsigned int stage0_get_core_clock_hz(void) {
    static unsigned int mbox_buf[8] __attribute__((aligned(16)));
    unsigned int addr, i;

    mbox_buf[0] = 32;          /* total size, bytes */
    mbox_buf[1] = 0;           /* request code */
    mbox_buf[2] = 0x00030002u; /* tag: get clock rate */
    mbox_buf[3] = 8;           /* value buffer size */
    mbox_buf[4] = 0;           /* tag req/resp code */
    mbox_buf[5] = 4;           /* clock id: 4 = CORE */
    mbox_buf[6] = 0;           /* rate in Hz (response) */
    mbox_buf[7] = 0;           /* end tag */

    addr = ((unsigned int)(unsigned long)mbox_buf & ~0xFu) | 8u; /* channel 8: property tags */

    for (i = 0; i < 100000u; i = i + 1) {
        if (!(mmio_r(MBOX_STATUS_ADDR) & MBOX_FULL)) break;
    }
    if (i == 100000u) return 0;

    mmio_w(MBOX_WRITE_ADDR, addr);

    for (i = 0; i < 100000u; i = i + 1) {
        if (!(mmio_r(MBOX_STATUS_ADDR) & MBOX_EMPTY)) {
            if (mmio_r(MBOX_READ_ADDR) == addr) {
                if (mbox_buf[1] == 0x80000000u) return mbox_buf[6];
                return 0;
            }
        }
    }
    return 0;
}

/* FIXED vs. the original port: after forcing the FSM out of READWAIT/
 * WRITESTART1/READDATA via SDEDM_FORCE_DATA_MODE_BIT, production
 * (kernel_main.vani's sdhost_force_data_mode_settle) polls (bounded,
 * 1000 iterations) for the FSM to genuinely settle into IDENTMODE/
 * DATAMODE, THEN clears the force bit either way -- the original port
 * set the force bit and immediately broke out of its own poll loop
 * without ever clearing it again, leaving SDEDM_FORCE_DATA_MODE_BIT
 * stuck set for the rest of the boot (every later CMD17/CMD24 this
 * program issues). Ported literally rather than re-derived. */
static void stage0_force_data_mode_settle(void) {
    int iter;
    unsigned int edm;
    for (iter = 0; iter < 1000; iter = iter + 1) {
        edm = mmio_r(SDEDM_ADDR);
        if ((edm & SDEDM_FSM_MASK) == SDEDM_FSM_IDENTMODE || (edm & SDEDM_FSM_MASK) == SDEDM_FSM_DATAMODE) {
            mmio_w(SDEDM_ADDR, edm & ~SDEDM_FORCE_DATA_MODE_BIT);
            return;
        }
    }
    edm = mmio_r(SDEDM_ADDR);
    mmio_w(SDEDM_ADDR, edm & ~SDEDM_FORCE_DATA_MODE_BIT);
}

/* Bring-up through CMD7 (SELECT_CARD), once per boot. Returns 0 on
 * success, or a negative stage code (-1 CMD0, -2 CMD8, -3 ACMD41,
 * -4 CMD2, -5 CMD3, -6 CMD9, -7 CMD7) matching uboot_sdhost_full.c's
 * own convention for the stages this file still shares with it. */
int stage0_sd_init(void) {
    struct cmd_result r;
    unsigned int retry;

    stage0_reset_and_ident_clock();

    stage0_send_cmd(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -1;

    /* FIXED vs. the recovered file (which also required the RSP0 echo
     * pattern to equal 0xAA): kernel_main.vani's own sdhost_init_at_
     * speed never validates CMD8's response content at all, only
     * whether the command CYCLE completed (sdhost_cmd_timed_out,
     * NEW_FLAG only) -- it reads+logs RSP0 unconditionally and
     * proceeds straight to ACMD41 regardless. This project's own
     * driver has only ever supported SD cards in practice (the MMC
     * fallback this echo-check would otherwise gate into is untested,
     * speculative code per that function's own comment) -- matching
     * production's permissive behavior here, rather than the
     * recovered file's own stricter check, is what the already-proven
     * reference actually does. */
    stage0_send_cmd(8, 0x1AAu, 1, 0, 0, 0, 0, 0, 0, 0, 1, &r);
    if (r.err != 0) return -2;

    /* FIXED vs. the recovered file, matching kernel_main.vani's own
     * ACMD41 loop exactly: production's check here is also
     * sdhost_cmd_timed_out-only (NEW_FLAG, never FAIL_FLAG) for both
     * CMD55 and CMD41, and it treats exhausting the retry cap without
     * ever seeing OCR_BUSY as a (flagged, non-fatal) warning rather
     * than a hard failure -- "proceeding anyway" is this project's
     * own pre-existing, deliberate behavior here, not a workaround.
     * A true command-cycle failure (NEW_FLAG stuck, r.err!=0) still
     * returns -3; only "busy bit never seen after 1000 tries" is
     * non-fatal. */
    retry = 1000;
    for (;;) {
        stage0_send_cmd(55, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, &r);
        if (r.err != 0) return -3;
        stage0_send_cmd(41, 0x00FF8000u | OCR_HCS, 1, 0, 0, 0, 0, 0, 0, 1, 1, &r);
        if (r.err != 0) return -3;
        if (r.response[0] & OCR_BUSY) break;
        if (retry == 0) break;
        retry = retry - 1;
        udelay_real(1000);
    }
    /* OCR_HCS/CCS, same bit position in the response as in the request
     * -- 1 means the card is block-addressed (SDHC/SDXC), 0 means
     * byte-addressed (SDSC). See this file's own header comment: the
     * recovered uboot_sdhost_full.c never captured this. */
    s_is_sdhc = (r.response[0] & OCR_HCS) ? 1 : 0;

    stage0_send_cmd(2, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -4;

    stage0_send_cmd(3, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -5;
    s_rca = (r.response[0] >> 16) & 0xFFFFu;

    stage0_send_cmd(9, s_rca << 16, 1, 1, 0, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -6;

    stage0_send_cmd(7, s_rca << 16, 1, 0, 1, 0, 0, 0, 0, 0, 0, &r);
    if (r.err != 0) return -7;

    /* Data-transfer clock + SDHCFG, 1-bit mode always (no ACMD6, no
     * WIDE_EXT_BUS). Target 1MHz, matching kernel_main.vani's own
     * sdhost_init() -> sdhost_init_at_speed(1000000) exactly -- real
     * divisor computed from the REAL core clock (see stage0_get_core_
     * clock_hz's own comment for why a hardcoded divisor isn't safe
     * on real silicon), same formula both real Linux and U-Boot use:
     * div = max_clk/target; if div<2 div=2; if (max_clk/div)>target
     * div+=1; div-=2; clamp to 0x7FF. Falls back to leaving SDCDIV at
     * the already-proven identification-speed divisor (0x148, set in
     * stage0_reset_and_ident_clock above) if the mailbox query fails
     * -- never speeds the controller up on an unconfirmed base clock,
     * matching production's own fallback discipline. SDHCFG write
     * (SLOW_CARD|DATA_IRPT_EN|BUSY_IRPT_EN|WIDE_INT_BUS, 0x418, real
     * U-Boot's bcm2835_set_ios sets WIDE_INT_BUS unconditionally
     * regardless of external bus width) happens either way. */
    {
        unsigned int core_clock_hz = stage0_get_core_clock_hz();
        unsigned int target_hz = 1000000u;
        if (core_clock_hz > 0u) {
            unsigned int max_div = 0x7FFu;
            unsigned int div0 = core_clock_hz / target_hz;
            unsigned int div1 = (div0 < 2u) ? 2u : div0;
            unsigned int div2 = ((core_clock_hz / div1) > target_hz) ? (div1 + 1u) : div1;
            unsigned int div3 = div2 - 2u;
            unsigned int div4 = (div3 > max_div) ? max_div : div3;
            unsigned int achieved_clock_hz = core_clock_hz / (div4 + 2u);
            mmio_w(SDCDIV_ADDR, div4);
            mmio_w(SDTOUT_ADDR, achieved_clock_hz / 2u);
            /* Settle delay after the clock-divisor change, before the
             * first data command -- matches production's own fix
             * (round 2026-09-18) for the exact same real-hardware
             * wedge class this is guarding against. */
            udelay_real(10000u);
        }
    }
    /* FIXED vs. the original port: 0x418 (DATA_IRPT_EN|BUSY_IRPT_EN|
     * SLOW_CARD) does NOT match kernel_main.vani's own current, real-
     * hardware-proven 1-bit-mode value (0x40A = WIDE_INT_BUS|SLOW_CARD|
     * BUSY_IRPT_EN -- no DATA_IRPT_EN) -- this project's own 19th/27th/
     * 30th/42nd SD rounds each found a real wedge/FIFO_ERROR tied to
     * getting exactly this register's bits wrong, and stage0's port
     * never incorporated any of those fixes. Only a conservative init-
     * time default here; the real, authoritative write happens inside
     * stage0_sd_read_block/stage0_sd_write_block below, matching
     * production's own per-call rewrite (never just once at init). */
    mmio_w(SDHCFG_ADDR, 0x40Au);

    return 0;
}

/* Reads exactly one 512-byte block into buf. Returns 0 on success,
 * negative on failure. Callable many times after one stage0_sd_init(). */
int stage0_sd_read_block(unsigned int block_num, void *buf) {
    struct cmd_result rr;
    unsigned int *rbuf = (unsigned int *)buf;
    unsigned int addr = s_is_sdhc ? block_num : (block_num * 512u);
    int copy_words;
    long long room_wait_iters;
    unsigned int sdhsts2;

    /* FIXED vs. the original port: real U-Boot (drivers/mmc/mmc_read.c
     * mmc_bread) reissues CMD16 (SET_BLOCKLEN) before EVERY single
     * read, never just once at init -- matching kernel_main.vani's own
     * sdhost_read_block_once exactly (round 2026-09-26). Result
     * deliberately ignored, matching production's own `let _ =` --
     * same reasoning: a card whose own notion of "current block
     * length" has drifted is exactly the class of bug this guards
     * against, and re-asserting it costs nothing. SDHCFG is rewritten
     * here too (also per-call in production, not just once at init) --
     * see stage0_sd_init's own comment for why 0x40A, not 0x418. */
    stage0_send_cmd(16, 512u, 1, 0, 0, 0, 0, 0, 0, 0, 0, &rr);
    mmio_w(SDHCFG_ADDR, 0x40Au);

    stage0_send_cmd(17, addr, 1, 0, 0, 512, 1, 1, 0, 0, 0, &rr);
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
                stage0_force_data_mode_settle();
                break;
            }
            if (elapsed_at_least(t0, TIMEOUT_US)) return -9;
        }
    }

    sdhsts2 = mmio_r(SDHSTS_ADDR) & SDHSTS_ERROR_MASK;
    mmio_w(SDHSTS_ADDR, sdhsts2);
    if (sdhsts2 != 0) return -9;

    return 0;
}

/* Writes exactly one 512-byte block from buf. Phase 3 addition --
 * used ONLY for the slot-state record (1 block, once per boot, to
 * persist an incremented attempt_count/bumped generation/possibly-
 * flipped active_slot before jumping) -- see this file's own header
 * comment. Mirrors stage0_sd_read_block's own shape (CMD24 instead of
 * CMD17, filling SDDATA instead of draining it), reusing the same
 * stage0_send_cmd dispatcher rather than porting boot/rpi1/uboot_
 * sdhost_write.c's own special-purpose sequence verbatim. */
int stage0_sd_write_block(unsigned int block_num, const void *buf) {
    struct cmd_result rr;
    const unsigned int *wbuf = (const unsigned int *)buf;
    unsigned int addr = s_is_sdhc ? block_num : (block_num * 512u);
    int fill_words;
    long long room_wait_iters;
    unsigned int sdhsts2;

    /* FIXED vs. the original port -- see stage0_sd_read_block's own
     * matching comment for the full "why" (CMD16 reissue + correct
     * SDHCFG, both per-call in production, matching sdhost_write_
     * block_once exactly). */
    stage0_send_cmd(16, 512u, 1, 0, 0, 0, 0, 0, 0, 0, 0, &rr);
    mmio_w(SDHCFG_ADDR, 0x40Au);

    stage0_send_cmd(24, addr, 1, 0, 0, 512, 1, 0, 1, 0, 0, &rr);
    if (rr.err != 0) return -9;

    fill_words = 128;
    room_wait_iters = 0;
    while (fill_words > 0) {
        unsigned int edm = mmio_r(SDEDM_ADDR);
        int fill = (int)((edm >> 4) & 0x1Fu);
        int room = 16 - fill;
        int burst_words = (SDDATA_FIFO_PIO_BURST < fill_words) ? SDDATA_FIFO_PIO_BURST : fill_words;
        int words;
        if (room < burst_words) {
            room_wait_iters = room_wait_iters + 1;
            if (room_wait_iters > 20000000LL) return -9;
            continue;
        }
        words = room;
        if (words > fill_words) words = fill_words;
        fill_words = fill_words - words;
        while (words > 0) {
            mmio_w(SDDATA_ADDR, *wbuf);
            wbuf = wbuf + 1;
            words = words - 1;
        }
    }

    /* FIXED vs. the original port: missing the FreeBSD-derived "wait
     * until FIFO is really empty" poll (round 2026-09-20, task #278)
     * production's own write path added after finding the fill loop's
     * own exit (room for the last word, not confirmed-drained) left a
     * real gap before checking FSM state. Bounded, matching
     * production's own 1,000,000-iteration cap -- a timeout here is
     * informational, never fatal (production doesn't fail the
     * transfer on it either), since the FSM-state poll right below
     * this is still the real correctness gate. */
    {
        long long fifo_drain_iter = 0;
        while (fifo_drain_iter < 1000000LL) {
            unsigned int edm = mmio_r(SDEDM_ADDR);
            if (((edm >> 4) & 0x1Fu) == 0u) break;
            fifo_drain_iter = fifo_drain_iter + 1;
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
                stage0_force_data_mode_settle();
                break;
            }
            if (elapsed_at_least(t0, TIMEOUT_US)) return -9;
        }
    }

    sdhsts2 = mmio_r(SDHSTS_ADDR) & SDHSTS_ERROR_MASK;
    mmio_w(SDHSTS_ADDR, sdhsts2);
    if (sdhsts2 != 0) return -9;

    return 0;
}

/* -nostdlib means no libc memcpy -- GCC's optimizer still recognizes
 * struct-assignment and array-copy patterns in stage0_main.c and
 * emits calls to it regardless. Trivial byte-wise implementation,
 * correctness over speed (this only ever copies a 512-byte block
 * buffer or small structs, never performance-critical). */
void *memcpy(void *dest, const void *src, unsigned long n) {
    unsigned char *d = (unsigned char *)dest;
    const unsigned char *s = (const unsigned char *)src;
    unsigned long i;
    for (i = 0; i < n; i = i + 1) d[i] = s[i];
    return dest;
}
