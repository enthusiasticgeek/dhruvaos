/* Stage-0 A/B kernel-slot loader -- C entry point.
 *
 * Phase 3: real attempt-counter/bootlimit/ready-flag/fallback logic,
 * plus a per-boot SHA-256 verification of the chosen slot's payload
 * before ever jumping into it (not just trusting the `ready` flag --
 * see this file's own sha256.c for why re-verifying on every boot,
 * not just once at upload time, is worth its cost here). Sequence:
 *   1. Read both slot-state ping-pong copies, pick the CRC-valid one
 *      with the higher generation (defaults to a fresh all-zero
 *      state if neither is valid -- a blank/corrupt card, handled
 *      the same way Phase 1/2 already did).
 *   2. Increment the chosen active slot's attempt_count.
 *   3. If attempt_count > bootlimit AND the OTHER slot is `ready`,
 *      flip active_slot to the other one and reset its counter to 0
 *      -- U-Boot's own bootcount/bootlimit/altbootcmd mechanism,
 *      combined with Android A/B's per-slot `ready` gate so a slot
 *      that was never successfully uploaded is never auto-selected.
 *   4. Write the updated record back to the STALE ping-pong block
 *      (bumped generation) before touching anything else -- so even
 *      if the chosen slot's payload turns out to be corrupt below,
 *      the NEXT boot already sees the incremented attempt (or the
 *      flip), rather than retrying the same bad choice forever.
 *   5. Load the (possibly just-flipped) active slot's payload and
 *      verify its SHA-256 against the recorded digest. A mismatch is
 *      treated exactly like a failed boot attempt already was in
 *      step 2/3 -- it does NOT get its own extra fallback attempt;
 *      the counter write in step 4 already accounted for this boot,
 *      so a persistently corrupt slot converges to the other slot
 *      within `bootlimit` reboots as a straightforward consequence,
 *      no special-case code needed here.
 *   6. Jump, passing r0 = active_slot (0 or 1).
 */

#define BLOCK_SIZE 512u
#define SLOT_STATE_BLOCK_A 9216u
#define SLOT_STATE_BLOCK_B 9217u
#define SLOT_A_BASE_BLOCK 10240u
#define SLOT_B_BASE_BLOCK 22528u
#define SLOT_SIZE_BYTES (12288u * 512u)
#define REAL_KERNEL_LOAD_ADDR 0x00200000u
#define DEFAULT_BOOTLIMIT 3u

/* TASK #353 (2026-10-12, found during task #352's own Phase 6
 * drilling): stage0 used to jump to the chosen slot with NOTHING
 * armed to recover it if that slot hangs before the real kernel's own
 * watchdog_kick() calls ever run (kernel/kernel_main.vani's own
 * WATCHDOG_ENABLE_FOR_REAL_HARDWARE, gated off by default) -- exactly
 * the case for a deliberately-bad kernel (boot/badkernel/bad_entry.S,
 * a bare infinite self-branch) used to drill the auto-revert path,
 * and for any of the three real, QEMU-invisible hangs this same round
 * already found and fixed one level further in (mmu_init.S's page
 * table/missing ISB, this file's own missing pre-jump barrier). With
 * no one physically at the board, a hang here has NO recovery path at
 * all except a physical power cycle.
 *
 * Off (0) by default, same convention as WATCHDOG_ENABLE_FOR_REAL_
 * HARDWARE -- QEMU's raspi1ap resets the WHOLE emulated machine
 * IMMEDIATELY on the very first PM_RSTC write regardless of the
 * timeout value actually requested (this file's own sibling comment
 * in kernel_main.vani documents this, confirmed against QEMU's own
 * source), so leaving this unconditionally on would make every
 * existing QEMU-driven regression test (phase4_milestone.py,
 * phase5_markbootgood_test.py, ...) immediately "reset" the instant
 * this code ran, long before any of them could reach PASS. A real
 * preprocessor #if (unlike kernel_main.vani's own runtime `if const
 * == 1`, forced by vani having no conditional compilation) means this
 * compiles out to literally nothing when off -- flip to 1 and rebuild
 * stage0.img specifically before a real, unattended deployment (and
 * flip kernel_main.vani's own matching
 * STAGE0_PREJUMP_WATCHDOG_DISARM_FOR_REAL_HARDWARE to 1 too, so a
 * healthy boot disarms this at PASS instead of getting reset by its
 * own safety net mid-session).
 *
 * TASK #353 FOLLOW-UP (2026-10-15): made build-time overridable via
 * -D on the command line (build_stage0.sh's own STAGE0_CFLAGS env
 * var) instead of only a hand-edit-build-revert cycle on this literal
 * -- same real deployment this was always meant for, just without the
 * risk of forgetting to revert a hand edit to the checked-in default
 * before the next ordinary QEMU-driven build. Checked-in default
 * stays 0, unchanged. */
#ifndef STAGE0_PREJUMP_WATCHDOG_FOR_REAL_HARDWARE
#define STAGE0_PREJUMP_WATCHDOG_FOR_REAL_HARDWARE 0
#endif

#if STAGE0_PREJUMP_WATCHDOG_FOR_REAL_HARDWARE
/* Same BCM2835 PM_WDOG/PM_RSTC register protocol as kernel_main.vani's
 * own watchdog_arm (PM_RSTC=0x2010001C, PM_WDOG=0x20100024, password
 * 0x5A000000 required in the top byte of every write to either
 * register or the write is silently ignored, ticks run at a fixed
 * 65536Hz independent of any scheduler tick period) -- reusing the
 * exact proven sequence, not re-deriving it. 15 seconds (983040 =
 * 15<<16 ticks) is comfortably under the register's own 0xFFFFF-tick
 * (~16s) ceiling, generous margin above the ~200ms this file's own
 * real-HW logs show boot.S's prologue + mmu_init + sdhost_init
 * actually take (the one gap this specific arm needs to cover: from
 * here to kernel_main's own first watchdog_kick() call) while still
 * short enough that a genuinely bad/hung jump target gets caught
 * quickly rather than left spinning for a long time unattended. */
#define PM_RSTC 0x2010001Cu
#define PM_WDOG 0x20100024u
static void stage0_arm_watchdog(void) {
    volatile unsigned int *rstc = (volatile unsigned int *)PM_RSTC;
    volatile unsigned int *wdog = (volatile unsigned int *)PM_WDOG;
    unsigned int password = 0x5A000000u;
    unsigned int wrcfg_clr = 0xFFFFFFCFu;
    unsigned int wrcfg_full_reset = 0x00000020u;
    unsigned int fifteen_seconds_in_ticks = 983040u; /* 15 << 16 */
    unsigned int cur;
    *wdog = password | (fifteen_seconds_in_ticks & 0xFFFFFu);
    /* 2026-10-23 audit (same class as the UART overrun-clear fix in
     * kernel_main.vani): `volatile` here only orders the compiler,
     * not the hardware -- this peripheral region is Shareable
     * Device memory, not Strongly Ordered. Negligible real risk
     * (PM_WDOG/PM_RSTC are independent registers and the watchdog
     * fires asynchronously seconds later regardless), added for
     * consistency with every other MMIO write-then-cross-register-
     * access site fixed this round. */
    __asm__ volatile ("mcr p15, 0, %0, c7, c10, 4" :: "r"(0) : "memory");
    cur = *rstc;
    *rstc = password | (cur & wrcfg_clr) | wrcfg_full_reset;
    __asm__ volatile ("mcr p15, 0, %0, c7, c10, 4" :: "r"(0) : "memory");
}
#endif

extern void u_putc(char c);
extern void u_puts(const char *s);
extern void u_hex32(unsigned int v);
extern int stage0_sd_init(void);
extern int stage0_sd_read_block(unsigned int block_num, void *buf);
extern int stage0_sd_write_block(unsigned int block_num, const void *buf);

struct sha256_ctx { unsigned int h[8]; unsigned char buf[64]; unsigned int buf_len; unsigned long long total_len; };
extern void sha256_init(struct sha256_ctx *ctx);
extern void sha256_update(struct sha256_ctx *ctx, const unsigned char *data, unsigned int len);
extern void sha256_finalize(struct sha256_ctx *ctx, unsigned char out[32]);

/* Standard IEEE 802.3 / zlib CRC32 (reflected, poly 0xEDB88320),
 * bit-by-bit -- matches test/kernel_slot_layout.py's zlib.crc32
 * exactly, needed since this record crosses the host-tool/stage-0
 * boundary and must use the identical algorithm on both sides. Runs
 * once per boot over a 96-byte record; a table-based version would
 * only save microseconds nobody will ever notice here. */
static unsigned int crc32_bytes(const unsigned char *data, unsigned int len) {
    unsigned int crc = 0xFFFFFFFFu;
    unsigned int i, j;
    for (i = 0; i < len; i = i + 1) {
        crc = crc ^ data[i];
        for (j = 0; j < 8; j = j + 1) {
            if (crc & 1u) {
                crc = (crc >> 1) ^ 0xEDB88320u;
            } else {
                crc = crc >> 1;
            }
        }
    }
    return crc ^ 0xFFFFFFFFu;
}

static unsigned int read_u32_le(const unsigned char *buf, unsigned int off) {
    return (unsigned int)buf[off]
         | ((unsigned int)buf[off + 1] << 8)
         | ((unsigned int)buf[off + 2] << 16)
         | ((unsigned int)buf[off + 3] << 24);
}

static void write_u32_le(unsigned char *buf, unsigned int off, unsigned int v) {
    buf[off] = (unsigned char)v;
    buf[off + 1] = (unsigned char)(v >> 8);
    buf[off + 2] = (unsigned char)(v >> 16);
    buf[off + 3] = (unsigned char)(v >> 24);
}

/* Task #308 follow-up ("I need unattended debugging"/"reset reason"):
 * REASON_* values for last_reset_reason below -- see test/kernel_
 * slot_layout.py's own matching struct comment for the on-disk byte
 * offset. Backward-compatible: an old record's zeroed reserved byte
 * already decodes as REASON_POWER_ON. */
#define REASON_POWER_ON 0u
#define REASON_CLEAN_REBOOT 1u
#define REASON_WATCHDOG_OR_HANG 2u
#define REASON_AUTO_FALLBACK 3u

struct slot_state {
    unsigned int generation;
    unsigned char active_slot;
    unsigned char preferred_slot;
    unsigned char last_reset_reason;
    unsigned int attempt_count;
    unsigned int bootlimit;
    unsigned char slot_a_ready;
    unsigned char slot_b_ready;
    unsigned int slot_a_len;
    unsigned int slot_b_len;
    unsigned char slot_a_sha256[32];
    unsigned char slot_b_sha256[32];
};

/* Parses+validates one 512-byte slot-state block (magic + CRC32 over
 * bytes 0..95, exact layout matching test/kernel_slot_layout.py's
 * _STRUCT_FMT). Returns 1 if valid (fills *out), 0 otherwise. */
static int parse_slot_state(const unsigned char *raw, struct slot_state *out) {
    unsigned int magic = read_u32_le(raw, 0);
    unsigned int crc_stored = read_u32_le(raw, 96);
    unsigned int crc_actual;
    int i;
    if (magic != 0x44485342u) return 0;
    crc_actual = crc32_bytes(raw, 96);
    if (crc_actual != crc_stored) return 0;

    out->generation = read_u32_le(raw, 4);
    out->active_slot = raw[8];
    out->preferred_slot = raw[9];
    out->last_reset_reason = raw[10];
    out->attempt_count = read_u32_le(raw, 12);
    out->bootlimit = read_u32_le(raw, 16);
    out->slot_a_ready = raw[20];
    out->slot_b_ready = raw[21];
    out->slot_a_len = read_u32_le(raw, 24);
    out->slot_b_len = read_u32_le(raw, 28);
    for (i = 0; i < 32; i = i + 1) {
        out->slot_a_sha256[i] = raw[32 + i];
        out->slot_b_sha256[i] = raw[64 + i];
    }
    return 1;
}

/* Serializes *s into a fresh 512-byte block (zero-padded past byte
 * 100), computing the CRC32 over the resulting bytes 0..95 -- the
 * write-side mirror of parse_slot_state, matching test/kernel_slot_
 * layout.py's pack_state byte-for-byte. */
static void build_slot_state(const struct slot_state *s, unsigned char *out) {
    unsigned int crc;
    int i;
    for (i = 0; i < (int)BLOCK_SIZE; i = i + 1) out[i] = 0;
    write_u32_le(out, 0, 0x44485342u);
    write_u32_le(out, 4, s->generation);
    out[8] = s->active_slot;
    out[9] = s->preferred_slot;
    out[10] = s->last_reset_reason;
    write_u32_le(out, 12, s->attempt_count);
    write_u32_le(out, 16, s->bootlimit);
    out[20] = s->slot_a_ready;
    out[21] = s->slot_b_ready;
    write_u32_le(out, 24, s->slot_a_len);
    write_u32_le(out, 28, s->slot_b_len);
    for (i = 0; i < 32; i = i + 1) {
        out[32 + i] = s->slot_a_sha256[i];
        out[64 + i] = s->slot_b_sha256[i];
    }
    crc = crc32_bytes(out, 96);
    write_u32_le(out, 96, crc);
}

void stage0_fault(unsigned int code) {
    u_puts("\nstage0: FATAL, halting (code=0x");
    u_hex32(code);
    u_puts(")\n");
    for (;;) { }
}

void stage0_main(void) {
    static unsigned char block_buf[BLOCK_SIZE];
    struct slot_state a_state, b_state, chosen;
    int have_a, have_b, have_chosen;
    unsigned int stale_block;
    unsigned int base_block, len_bytes, nblocks, i;
    unsigned char *dest;
    unsigned char *expect_sha256;
    int rc;

    u_puts("\nstage0: A/B kernel-slot loader starting\n");

    rc = stage0_sd_init();
    if (rc != 0) {
        u_puts("stage0: SD init failed, stage=");
        u_hex32((unsigned int)rc);
        u_puts("\n");
        stage0_fault(0xDEAD0001u);
    }

    rc = stage0_sd_read_block(SLOT_STATE_BLOCK_A, block_buf);
    have_a = (rc == 0) && parse_slot_state(block_buf, &a_state);
    rc = stage0_sd_read_block(SLOT_STATE_BLOCK_B, block_buf);
    have_b = (rc == 0) && parse_slot_state(block_buf, &b_state);

    have_chosen = 0;
    stale_block = SLOT_STATE_BLOCK_B;
    if (have_a && have_b) {
        if (a_state.generation >= b_state.generation) {
            chosen = a_state;
            stale_block = SLOT_STATE_BLOCK_B;
        } else {
            chosen = b_state;
            stale_block = SLOT_STATE_BLOCK_A;
        }
        have_chosen = 1;
    } else if (have_a) {
        chosen = a_state;
        stale_block = SLOT_STATE_BLOCK_B;
        have_chosen = 1;
    } else if (have_b) {
        chosen = b_state;
        stale_block = SLOT_STATE_BLOCK_A;
        have_chosen = 1;
    }

    if (!have_chosen) {
        u_puts("stage0: no valid slot-state record found (blocks ");
        u_hex32(SLOT_STATE_BLOCK_A);
        u_puts("/");
        u_hex32(SLOT_STATE_BLOCK_B);
        u_puts(") -- fresh/corrupt card, nothing to boot\n");
        stage0_fault(0xDEAD0002u);
    }

    /* Task #308 follow-up ("I need unattended debugging"/"reset
     * reason"): capture the record's state exactly as read, BEFORE
     * this boot's own increment/fallback logic touches it, so the
     * reason computed below reflects what actually happened to the
     * PREVIOUS boot of this slot, not this one. prior_attempt_count
     * > 0 means the previous boot never reached kernel_slot_mark_
     * boot_good() (which always resets it to 0 on success) --
     * i.e. it was interrupted, by a hang+watchdog, a crash, or a raw
     * power loss, never a clean exit. prior_reason carries forward
     * whatever the kernel's own `reboot` shell command may have just
     * written right before resetting (REASON_CLEAN_REBOOT) -- the one
     * case prior_attempt_count alone can't distinguish, since a
     * deliberate reboot after a fully healthy boot also has
     * attempt_count==0. */
    unsigned int prior_attempt_count = chosen.attempt_count;
    unsigned char prior_reason = chosen.last_reset_reason;

    /* Step 2/3: increment the current active slot's attempt counter;
     * flip to the other slot if it's exhausted the bootlimit and the
     * other slot is ready. */
    chosen.attempt_count = chosen.attempt_count + 1;
    u_puts("stage0: active_slot=");
    u_putc(chosen.active_slot == 0 ? 'A' : 'B');
    u_puts(" attempt_count=");
    u_hex32(chosen.attempt_count);
    u_puts(" bootlimit=");
    u_hex32(chosen.bootlimit ? chosen.bootlimit : DEFAULT_BOOTLIMIT);
    u_puts("\n");

    int fell_back = 0;
    {
        unsigned int bootlimit = chosen.bootlimit ? chosen.bootlimit : DEFAULT_BOOTLIMIT;
        if (chosen.attempt_count > bootlimit) {
            unsigned char other_ready = (chosen.active_slot == 0) ? chosen.slot_b_ready : chosen.slot_a_ready;
            if (other_ready) {
                u_puts("stage0: bootlimit exceeded, falling back to slot ");
                chosen.active_slot = (chosen.active_slot == 0) ? 1 : 0;
                u_putc(chosen.active_slot == 0 ? 'A' : 'B');
                u_puts("\n");
                chosen.attempt_count = 0;
                fell_back = 1;
            } else {
                u_puts("stage0: bootlimit exceeded but other slot not ready, retrying active slot anyway\n");
            }
        }
    }

    /* Task #308 follow-up: decide this boot's own reset reason, for
     * the NEXT kernel boot to read back (see the "resetreason" shell
     * command, kernel_main.vani) -- precedence matches how
     * informative each case is: an auto-fallback is always worth
     * flagging even if it happens to follow a clean reboot (which
     * can't itself explain exhausting bootlimit); a clean reboot only
     * "counts" once, consumed here so the NEXT-next boot defaults
     * back to power-on rather than claiming every future boot was
     * also a clean reboot. */
    if (fell_back) {
        chosen.last_reset_reason = REASON_AUTO_FALLBACK;
    } else if (prior_reason == REASON_CLEAN_REBOOT) {
        chosen.last_reset_reason = REASON_CLEAN_REBOOT;
    } else if (prior_attempt_count > 0) {
        chosen.last_reset_reason = REASON_WATCHDOG_OR_HANG;
    } else {
        chosen.last_reset_reason = REASON_POWER_ON;
    }

    chosen.generation = chosen.generation + 1;

    build_slot_state(&chosen, block_buf);
    rc = stage0_sd_write_block(stale_block, block_buf);
    if (rc != 0) {
        u_puts("stage0: WARNING slot-state write-back failed (block ");
        u_hex32(stale_block);
        u_puts("), continuing anyway\n");
    }

    if (chosen.active_slot == 0) {
        base_block = SLOT_A_BASE_BLOCK;
        len_bytes = chosen.slot_a_len;
        expect_sha256 = chosen.slot_a_sha256;
    } else {
        base_block = SLOT_B_BASE_BLOCK;
        len_bytes = chosen.slot_b_len;
        expect_sha256 = chosen.slot_b_sha256;
    }

    if (len_bytes == 0 || len_bytes > SLOT_SIZE_BYTES) {
        u_puts("stage0: active slot has invalid recorded length\n");
        stage0_fault(0xDEAD0003u);
    }

    u_puts("stage0: loading len=0x");
    u_hex32(len_bytes);
    u_puts("\n");

    nblocks = (len_bytes + BLOCK_SIZE - 1u) / BLOCK_SIZE;
    dest = (unsigned char *)REAL_KERNEL_LOAD_ADDR;
    for (i = 0; i < nblocks; i = i + 1) {
        rc = stage0_sd_read_block(base_block + i, block_buf);
        if (rc != 0) {
            u_puts("stage0: read failed at block offset ");
            u_hex32(i);
            u_puts("\n");
            stage0_fault(0xDEAD0004u);
        }
        {
            unsigned int b;
            for (b = 0; b < BLOCK_SIZE; b = b + 1) {
                dest[b] = block_buf[b];
            }
        }
        dest = dest + BLOCK_SIZE;
    }

    {
        struct sha256_ctx ctx;
        unsigned char actual[32];
        int match;
        sha256_init(&ctx);
        sha256_update(&ctx, (const unsigned char *)(unsigned long)REAL_KERNEL_LOAD_ADDR, len_bytes);
        sha256_finalize(&ctx, actual);
        match = 1;
        for (i = 0; i < 32; i = i + 1) {
            if (actual[i] != expect_sha256[i]) { match = 0; break; }
        }
        if (!match) {
            u_puts("stage0: payload SHA-256 mismatch, refusing to jump\n");
            stage0_fault(0xDEAD0006u);
        }
    }

    /* TASK #352 FIX (2026-10-12, real-HW dress rehearsal): a fresh
     * multi-boot real-HW capture after the mmu_init.S ISB fix showed a
     * NEW failure mode, distinct from (and earlier than) the mmu_init
     * hang this same investigation already fixed twice: some boots
     * now hang with ZERO UART output at all -- not even boot.S's own
     * very first RAW_DIAG_PUTC('A') -- immediately after this
     * function's own "verified, jumping to 0x00200000" line, which
     * DOES print successfully every time. That boundary is exactly
     * where this function stops controlling memory (the block-copy
     * loop above, writing the just-read kernel payload byte-for-byte
     * into RAM at REAL_KERNEL_LOAD_ADDR) and starts trusting it (the
     * jump below, fetching instructions from that same address) --
     * with NO barrier of any kind between the two, unlike every other
     * place in this codebase that writes code/tables it's about to
     * rely on (stage0_entry.S's own defensive invalidate above;
     * mmu_init.S's SCTLR-enable ISB fix, same commit series). Real
     * bootloaders universally insert exactly this barrier before
     * jumping into freshly-loaded code (U-Boot's own `bootm`/`go`,
     * the Linux zImage decompressor) -- its absence here was a real
     * gap, not a defensive guess. QEMU's TCG core has no write-buffer
     * or instruction-prefetch model at all, so a race between the
     * last written byte actually reaching memory and the CPU fetching
     * from that same address as code is invisible under every one of
     * this session's QEMU-verified tests by construction -- same
     * class of QEMU-vs-real-HW divergence as the two fixes before it,
     * which also explains why this only ever showed up intermittently
     * on real hardware, never in QEMU.
     *
     * Same instruction sequence as stage0_entry.S's own defensive
     * invalidate (that file's own comment for why each one matters):
     * DSB (drain the write buffer -- the actual fix for this specific
     * race), then I+D cache invalidate, TLB invalidate, branch-
     * predictor invalidate, and ISB (flush prefetch buffer) -- belt
     * and suspenders, not just the one instruction theoretically
     * required, matching this project's own established convention
     * for "about to trust memory state I'm not certain is settled". */
    __asm__ volatile (
        "mov r0, #0\n"
        "mcr p15, 0, r0, c7, c10, 4\n"
        "mcr p15, 0, r0, c7, c7, 0\n"
        "mcr p15, 0, r0, c8, c7, 0\n"
        "mcr p15, 0, r0, c7, c5, 6\n"
        "mcr p15, 0, r0, c7, c10, 4\n"
        "mcr p15, 0, r0, c7, c5, 4\n"
        ::: "r0", "memory"
    );

    u_puts("stage0: verified, jumping to 0x00200000\n");

#if STAGE0_PREJUMP_WATCHDOG_FOR_REAL_HARDWARE
    stage0_arm_watchdog();
#endif

    {
        /* Task #308 follow-up: pack the reset reason into the upper
         * byte of the r0 handoff, slot index unchanged in the low
         * byte -- boot/rpi1/boot.S's own getter masks each back out
         * separately (see its own comment). */
        void (*entry)(unsigned int) = (void (*)(unsigned int))REAL_KERNEL_LOAD_ADDR;
        entry(((unsigned int)chosen.last_reset_reason << 8) | (unsigned int)chosen.active_slot);
    }

    /* Never reached -- entry() does not return. */
    stage0_fault(0xDEAD0005u);
}
