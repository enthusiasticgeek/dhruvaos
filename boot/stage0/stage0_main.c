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

struct slot_state {
    unsigned int generation;
    unsigned char active_slot;
    unsigned char preferred_slot;
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
            } else {
                u_puts("stage0: bootlimit exceeded but other slot not ready, retrying active slot anyway\n");
            }
        }
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

    u_puts("stage0: verified, jumping to 0x00200000\n");

    {
        void (*entry)(unsigned int) = (void (*)(unsigned int))REAL_KERNEL_LOAD_ADDR;
        entry((unsigned int)chosen.active_slot);
    }

    /* Never reached -- entry() does not return. */
    stage0_fault(0xDEAD0005u);
}
