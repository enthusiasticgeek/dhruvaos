/* Stage-0 A/B kernel-slot loader -- C entry point.
 *
 * Phase 2 scope (see the plan this came from): load a single slot
 * (whichever the slot-state record's active_slot field names) and
 * chain-load the real kernel from it. Deliberately NOT yet
 * implemented here: attempt-counter increment/compare, auto-fallback
 * to the other slot, and checksum verification before jumping -- all
 * Phase 3. This phase only needs to prove the chain-load mechanism
 * itself works (QEMU first, then real HW) before any of that safety
 * logic is layered on top of it.
 */

#define BLOCK_SIZE 512u
#define SLOT_STATE_BLOCK_A 9216u
#define SLOT_STATE_BLOCK_B 9217u
#define SLOT_A_BASE_BLOCK 10240u
#define SLOT_B_BASE_BLOCK 22528u
#define REAL_KERNEL_LOAD_ADDR 0x00200000u

extern void u_putc(char c);
extern void u_puts(const char *s);
extern void u_hex32(unsigned int v);
extern int stage0_sd_init(void);
extern int stage0_sd_read_block(unsigned int block_num, void *buf);

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
};

/* Parses+validates one 512-byte slot-state block (magic + CRC32 over
 * bytes 0..95, exact layout matching test/kernel_slot_layout.py's
 * _STRUCT_FMT). Returns 1 if valid (fills *out), 0 otherwise. */
static int parse_slot_state(const unsigned char *raw, struct slot_state *out) {
    unsigned int magic = read_u32_le(raw, 0);
    unsigned int crc_stored = read_u32_le(raw, 96);
    unsigned int crc_actual;
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
    return 1;
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
    unsigned int base_block, len_bytes, nblocks, i;
    unsigned char *dest;
    int rc;

    u_puts("\nstage0: A/B kernel-slot loader starting\n");

    rc = stage0_sd_init();
    if (rc != 0) {
        u_puts("stage0: SD init failed, stage=");
        u_hex32((unsigned int)rc);
        u_puts("\n");
        stage0_fault(0xDEAD0001u);
    }
    u_puts("stage0: SD init ok\n");

    rc = stage0_sd_read_block(SLOT_STATE_BLOCK_A, block_buf);
    have_a = (rc == 0) && parse_slot_state(block_buf, &a_state);
    rc = stage0_sd_read_block(SLOT_STATE_BLOCK_B, block_buf);
    have_b = (rc == 0) && parse_slot_state(block_buf, &b_state);

    have_chosen = 0;
    if (have_a && have_b) {
        chosen = (a_state.generation >= b_state.generation) ? a_state : b_state;
        have_chosen = 1;
    } else if (have_a) {
        chosen = a_state;
        have_chosen = 1;
    } else if (have_b) {
        chosen = b_state;
        have_chosen = 1;
    }

    if (!have_chosen) {
        u_puts("stage0: no valid slot-state record found (blocks ");
        u_hex32(SLOT_STATE_BLOCK_A);
        u_puts("/");
        u_hex32(SLOT_STATE_BLOCK_B);
        u_puts(")\n");
        stage0_fault(0xDEAD0002u);
    }

    if (chosen.active_slot == 0) {
        base_block = SLOT_A_BASE_BLOCK;
        len_bytes = chosen.slot_a_len;
    } else {
        base_block = SLOT_B_BASE_BLOCK;
        len_bytes = chosen.slot_b_len;
    }

    if (len_bytes == 0) {
        u_puts("stage0: active slot has zero recorded length\n");
        stage0_fault(0xDEAD0003u);
    }

    u_puts("stage0: active_slot=");
    u_putc(chosen.active_slot == 0 ? 'A' : 'B');
    u_puts(" len=0x");
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

    u_puts("stage0: loaded, jumping to 0x00200000\n");

    {
        void (*entry)(unsigned int) = (void (*)(unsigned int))REAL_KERNEL_LOAD_ADDR;
        entry((unsigned int)chosen.active_slot);
    }

    /* Never reached -- entry() does not return. */
    stage0_fault(0xDEAD0005u);
}
