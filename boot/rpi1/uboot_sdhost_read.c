/* 41st SD round (2026-09-27): literal C transliteration of real U-Boot's
 * own bcm2835_sdhost.c READ path -- mirrors boot/rpi1/uboot_sdhost_
 * write.c's own write-side port exactly (same file-level rationale,
 * same self-contained/no-shared-headers approach, see that file's own
 * header comment for the full "why"). Built after the 40th round's
 * real-HW retest: the ACMD6 fix enabled genuine 4-bit mode, and for
 * the first time in this entire saga every write on the 8-block sweep
 * succeeds cleanly -- but every READ then fails with FIFO_ERROR
 * (0x08, not CRC16) and a stale, repeating readback pattern.
 *
 * WHILE PORTING THIS, found a real gap: real U-Boot's own
 * bcm2835_transfer_block_pio has an FSM-state sanity check INSIDE its
 * burst-readiness poll loop --
 *
 *   if (words < burst_words) {
 *       int fsm_state = (edm & SDEDM_FSM_MASK);
 *       if ((is_read && fsm_state not one of READDATA/READWAIT/READCRC)
 *           || (!is_read && fsm_state not one of the WRITE* states)) {
 *           hsts = readl(SDHSTS);
 *           printf("fsm %x, hsts %08x\n", fsm_state, hsts);
 *           if (hsts & SDHSTS_ERROR_MASK)
 *               break;
 *       }
 *       continue;
 *   }
 *
 * -- an early, explicit exit the INSTANT the FSM leaves a valid
 * data-transfer state while still waiting for room/fill, reading
 * SDHSTS right then to see what happened. Neither DhruvaOS's own
 * hand-written asm driver (boot/sdcard_state.S's own
 * sdhost_drain_fifo_to_buffer_impl/sdhost_fill_fifo_from_buffer_impl)
 * NOR uboot_sdhost_write.c's own earlier "literal" C port actually
 * has this check -- both just retry the bare fill/room threshold up
 * to a bounded cap, then (asm side) FORCE a read/write of stale data
 * anyway once the cap is exhausted, with no visibility into why the
 * FIFO was never ready. This is a very plausible, direct explanation
 * for the observed garbage/stale readback pattern (C3 C2 C1 C0
 * repeating): if a genuine FIFO_ERROR condition sets mid-transfer,
 * this driver's own loops have never had a way to detect it AT THE
 * POINT it happens, only well after, via the post-transfer SDHSTS
 * check -- by which point the data already read out is whatever
 * happened to be sitting in SDDATA, not real transferred bytes. This
 * port includes that check, faithfully, specifically to test this
 * hypothesis with direct real-HW evidence rather than another guess.
 * (uboot_sdhost_write.c's own burst loop lacks this same check --
 * noted here rather than silently fixed there too, since the write
 * side is currently working and per this project's own "verify
 * causally" discipline, an unrequested change there needs its own
 * separate real-HW confirmation, not a blind copy-paste.)
 *
 * Called ONLY from the existing 8-block real-HW diagnostic sweep
 * (block_num 2100-2107 -- see kernel_main.vani's sdhost_read_block_
 * once, use_write_diag-equivalent gate). The production read path
 * (every other block, DharaFS's entire real read traffic) is
 * completely untouched by this file. */

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
#define SDCMD_READ_CMD   0x40u
#define SDCMD_CMD_MASK   0x3fu

/* SDHSTS_ERROR_MASK = CMD_TIME_OUT(0x40) | CRC7_ERROR(0x10) |
 * CRC16_ERROR(0x20) | REW_TIME_OUT(0x80) | FIFO_ERROR(0x08) --
 * matches uboot_sdhost_write.c's own identical definition exactly. */
#define SDHSTS_ERROR_MASK 0xF8u

#define SDEDM_FSM_MASK        0xFu
#define SDEDM_FSM_IDENTMODE   0x0u
#define SDEDM_FSM_DATAMODE    0x1u
#define SDEDM_FSM_READDATA    0x2u
#define SDEDM_FSM_READWAIT    0x4u
#define SDEDM_FSM_READCRC     0x5u   /* confirmed via direct grep of real
                                       * U-Boot's bcm2835_sdhost.c; 0x3 is
                                       * actually SDEDM_FSM_WRITEDATA, an
                                       * unrelated write-side FSM state */
#define SDEDM_FSM_WRITESTART1 0xAu
#define SDEDM_FSM_FORCE_DATA_MODE_BIT (1u << 19)

#define SDDATA_FIFO_WORDS     16
#define SDDATA_FIFO_PIO_BURST 8

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

static int timed_out(unsigned int t0, unsigned int budget_us) {
    unsigned int now = now_us();
    return (now - t0) >= budget_us;
}

static void u_putc(char c) {
    volatile unsigned int *fr = (volatile unsigned int *)0x20201018;
    volatile unsigned int *dr = (volatile unsigned int *)0x20201000;
    while ((*fr) & 0x20) {
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

/* Same shape as uboot_sdhost_write.c's own dhruva_sd_diag_dump --
 * deliberately not shared code (this file's own header comment on why
 * these ports stay self-contained). */
static void dhruva_sd_diag_dump(const char *label) {
    u_puts("SD DIAG: ");
    u_puts(label);
    u_puts(" SDCMD=0x");
    u_hex32(mmio_r(SDCMD_ADDR));
    u_puts(" SDARG=0x");
    u_hex32(mmio_r(SDARG_ADDR));
    u_puts(" SDHBCT=0x");
    u_hex32(mmio_r(SDHBCT_ADDR));
    u_puts(" SDHBLC=0x");
    u_hex32(mmio_r(SDHBLC_ADDR));
    u_puts(" SDHSTS=0x");
    u_hex32(mmio_r(SDHSTS_ADDR));
    u_puts(" SDEDM=0x");
    u_hex32(mmio_r(SDEDM_ADDR));
    u_puts("\n");
}

/* long long / void* signature matching uboot_sdhost_write.c's own
 * convention exactly (same AAPCS register-pairing reasoning). buf_ptr
 * is a raw pointer to 128 sequential 32-bit words (512 bytes) to fill
 * from the card. block_addr is the already-computed CMD17 argument
 * (sdhost_card_addr's return value). Return convention mirrors
 * uboot_style_sdhost_write_block's own: 0=success, 1=command phase
 * timed out/never completed, 2=PIO/wait_transfer_complete wedge,
 * 3=SDHSTS error bits set after completion, 4=CMD17 FAIL_FLAG,
 * 5=FSM left a valid read state mid-burst-poll, 6=FSM not
 * IDENTMODE/DATAMODE before CMD17 was ever issued, 7=SDHSTS already
 * showed an error the instant the command phase completed, before the
 * PIO loop ever started (checks 6 and 7 are two more real gaps found
 * this same round while meticulously re-reading every function real
 * U-Boot's own bcm2835_send_cmd calls -- see this file's own header
 * comment for check 5; bcm2835_send_cmd's OWN leading FSM sanity check
 * and bcm2835_transmit's OWN leading SDHSTS check, both BEFORE this
 * driver's own command-issuance/PIO-loop code ever runs, were missing
 * from every C port in this project until now). */
long long uboot_style_sdhost_read_block(void *buf_ptr, long long block_addr) {
    unsigned int *buf = (unsigned int *)buf_ptr;
    unsigned int addr = (unsigned int)block_addr;
    unsigned int sdcmd;
    unsigned int sdhsts;
    unsigned int t0;

    dhruva_sd_diag_dump("pre-CMD17");

    /* bcm2835_send_cmd's OWN leading check, run before ANYTHING else --
     * even before bcm2835_send_command's own "wait for previous NEW_
     * FLAG to clear" loop: the FSM must already be IDENTMODE or
     * DATAMODE (genuinely idle) before a new command is issued at all.
     * Directly relevant here: this read (CMD17) is issued immediately
     * after the write (CMD24) that just succeeded, whose own wait_
     * transfer_complete forced the FSM back toward idle via the
     * FORCE_DATA_MODE bit -- if that transition hasn't actually
     * settled by the time this read starts, real U-Boot would catch it
     * HERE, with a clear diagnostic, rather than proceeding into a
     * doomed command. */
    {
        unsigned int edm0 = mmio_r(SDEDM_ADDR);
        unsigned int fsm0 = edm0 & SDEDM_FSM_MASK;
        if (fsm0 != SDEDM_FSM_IDENTMODE && fsm0 != SDEDM_FSM_DATAMODE) {
            u_puts("SD DIAG: uboot-port pre-CMD17 FSM not idle, SDEDM=0x");
            u_hex32(edm0);
            u_puts("\n");
            return 6;
        }
    }

    /* bcm2835_read_wait_sdcmd, called before issuing a new command. */
    t0 = now_us();
    while (mmio_r(SDCMD_ADDR) & SDCMD_NEW_FLAG) {
        if (timed_out(t0, TIMEOUT_US)) {
            u_puts("SD DIAG: uboot-port pre-CMD17 previous command never completed\n");
            return 1;
        }
    }

    /* bcm2835_send_command: "Clear any error flags". */
    sdhsts = mmio_r(SDHSTS_ADDR);
    if (sdhsts & SDHSTS_ERROR_MASK) {
        mmio_w(SDHSTS_ADDR, sdhsts);
    }

    /* bcm2835_prepare_data: SDHBCT/SDHBLC written BEFORE SDARG/SDCMD. */
    mmio_w(SDHBCT_ADDR, 512u);
    mmio_w(SDHBLC_ADDR, 1u);

    mmio_w(SDARG_ADDR, addr);
    sdcmd = (17u & SDCMD_CMD_MASK) | SDCMD_READ_CMD;
    mmio_w(SDCMD_ADDR, sdcmd | SDCMD_NEW_FLAG);

    /* bcm2835_finish_command. */
    t0 = now_us();
    for (;;) {
        sdcmd = mmio_r(SDCMD_ADDR);
        if (!(sdcmd & SDCMD_NEW_FLAG)) {
            break;
        }
        if (timed_out(t0, TIMEOUT_US)) {
            u_puts("SD DIAG: uboot-port CMD17 command phase never completed\n");
            return 1;
        }
    }
    if (sdcmd & SDCMD_FAIL_FLAG) {
        sdhsts = mmio_r(SDHSTS_ADDR);
        mmio_w(SDHSTS_ADDR, SDHSTS_ERROR_MASK);
        u_puts("SD DIAG: uboot-port CMD17 FAIL_FLAG SDHSTS=0x");
        u_hex32(sdhsts);
        u_puts("\n");
        return 4;
    }

    dhruva_sd_diag_dump("post-CMD17-cmd-complete");

    /* bcm2835_transmit's OWN leading check -- runs BEFORE bcm2835_
     * transfer_pio/transfer_block_pio ever start, reading SDHSTS once
     * and checking it via bcm2835_check_data_error (CRC16|FIFO_ERROR|
     * REW_TIME_OUT) and bcm2835_check_cmd_error (CRC7|CRC16|FIFO_ERROR|
     * REW_TIME_OUT|CMD_TIME_OUT -- the two checks' bit sets overlap but
     * check_cmd_error additionally covers CRC7/CMD_TIME_OUT). Ported
     * here as a single combined check against the full SDHSTS_ERROR_
     * MASK, since both real checks together cover exactly that mask
     * and this driver has no separate host->cmd/host->data distinction
     * to preserve. Catches the case where SDHSTS already shows an
     * error the instant the command phase completes, before the PIO
     * burst loop below ever runs a single iteration. */
    {
        unsigned int pre_pio_hsts = mmio_r(SDHSTS_ADDR);
        if (pre_pio_hsts & SDHSTS_ERROR_MASK) {
            u_puts("SD DIAG: uboot-port pre-PIO SDHSTS already shows error=0x");
            u_hex32(pre_pio_hsts);
            u_puts("\n");
            return 7;
        }
    }

    /* bcm2835_transfer_block_pio (is_read = true), 128 words = one
     * 512-byte block. Unlike uboot_sdhost_write.c's own burst loop,
     * this one INCLUDES real U-Boot's own FSM-state sanity check
     * inside the burst-readiness poll (see this file's own header
     * comment) -- the actual real U-Boot source, not a simplified
     * threshold-only re-derivation. */
    {
        int copy_words = 128;
        long long fifo_wait_iters = 0;
        int fsm_exit = 0;

        while (copy_words > 0 && !fsm_exit) {
            unsigned int edm = mmio_r(SDEDM_ADDR);
            int fill = (int)((edm >> 4) & 0x1Fu);
            int burst_words = (SDDATA_FIFO_PIO_BURST < copy_words) ? SDDATA_FIFO_PIO_BURST : copy_words;
            int words;

            if (fill < burst_words) {
                unsigned int fsm_state = edm & SDEDM_FSM_MASK;
                if (fsm_state != SDEDM_FSM_READDATA &&
                    fsm_state != SDEDM_FSM_READWAIT &&
                    fsm_state != SDEDM_FSM_READCRC) {
                    unsigned int hsts = mmio_r(SDHSTS_ADDR);
                    u_puts("SD DIAG: uboot-port read burst-poll FSM left valid state fsm=0x");
                    u_hex32(fsm_state);
                    u_puts(" hsts=0x");
                    u_hex32(hsts);
                    u_puts(" fill=0x");
                    u_hex32((unsigned int)fill);
                    u_puts(" copy_words_remaining=0x");
                    u_hex32((unsigned int)copy_words);
                    u_puts("\n");
                    if (hsts & SDHSTS_ERROR_MASK) {
                        fsm_exit = 1;
                        continue;
                    }
                }
                fifo_wait_iters = fifo_wait_iters + 1;
                if (fifo_wait_iters > 20000000LL) {
                    u_puts("SD DIAG: uboot-port PIO burst-fill poll timed out SDEDM=0x");
                    u_hex32(edm);
                    u_puts("\n");
                    return 2;
                }
                continue;
            }

            words = fill;
            if (words > copy_words) {
                words = copy_words;
            }
            copy_words = copy_words - words;

            while (words > 0) {
                *(buf++) = mmio_r(SDDATA_ADDR);
                words--;
            }
        }

        if (fsm_exit) {
            return 5;
        }
    }

    /* bcm2835_transfer_pio's own post-transfer check -- identical to
     * uboot_sdhost_write.c's own. */
    sdhsts = mmio_r(SDHSTS_ADDR);
    if (sdhsts & (0x20u | 0x10u | 0x08u)) { /* CRC16 | CRC7 | FIFO_ERROR */
        u_puts("SD DIAG: uboot-port read transfer error SDHSTS=0x");
        u_hex32(sdhsts);
        u_puts("\n");
        return 3;
    }
    if (sdhsts & (0x40u | 0x80u)) { /* CMD_TIME_OUT | REW_TIME_OUT */
        u_puts("SD DIAG: uboot-port read transfer timeout error SDHSTS=0x");
        u_hex32(sdhsts);
        u_puts("\n");
        return 3;
    }

    /* bcm2835_wait_transfer_complete, identical to uboot_sdhost_
     * write.c's own (same function in real U-Boot serves both). */
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
            u_puts("SD DIAG: uboot-port read wait_transfer_complete timeout SDEDM=0x");
            u_hex32(edm);
            u_puts("\n");
            return 2;
        }
    }

    u_puts("SD DIAG: uboot-port read post-FSM-settle SDHSTS=0x");
    u_hex32(mmio_r(SDHSTS_ADDR));
    u_puts("\n");

    sdhsts = mmio_r(SDHSTS_ADDR) & SDHSTS_ERROR_MASK;
    mmio_w(SDHSTS_ADDR, sdhsts);
    if (sdhsts != 0) {
        u_puts("SD DIAG: uboot-port read post-wait SDHSTS error=0x");
        u_hex32(sdhsts);
        u_puts("\n");
        return 3;
    }

    return 0;
}
