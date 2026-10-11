/* Minimal, self-contained SHA-256 (FIPS 180-4), used only to verify a
 * kernel-slot payload's recorded digest before stage-0 jumps into it
 * (test/kernel_slot_layout.py's own `verify` subcommand and
 * kernel_main.vani's existing sha256_init/_update/_finalize compute
 * the SAME standard algorithm on the other two sides of this record's
 * digest field -- this is not a new format, just a third from-scratch
 * implementation of a completely standard one, since stage0 has no
 * vani dependency to share code with kernel_main.vani's own crypto,
 * and no libc to link a reference implementation from). Textbook,
 * unoptimized -- this runs once per boot, over at most 6MiB, and
 * correctness/auditability matters far more here than speed. */

#include <stddef.h>

static const unsigned int K[64] = {
    0x428a2f98u,0x71374491u,0xb5c0fbcfu,0xe9b5dba5u,0x3956c25bu,0x59f111f1u,0x923f82a4u,0xab1c5ed5u,
    0xd807aa98u,0x12835b01u,0x243185beu,0x550c7dc3u,0x72be5d74u,0x80deb1feu,0x9bdc06a7u,0xc19bf174u,
    0xe49b69c1u,0xefbe4786u,0x0fc19dc6u,0x240ca1ccu,0x2de92c6fu,0x4a7484aau,0x5cb0a9dcu,0x76f988dau,
    0x983e5152u,0xa831c66du,0xb00327c8u,0xbf597fc7u,0xc6e00bf3u,0xd5a79147u,0x06ca6351u,0x14292967u,
    0x27b70a85u,0x2e1b2138u,0x4d2c6dfcu,0x53380d13u,0x650a7354u,0x766a0abbu,0x81c2c92eu,0x92722c85u,
    0xa2bfe8a1u,0xa81a664bu,0xc24b8b70u,0xc76c51a3u,0xd192e819u,0xd6990624u,0xf40e3585u,0x106aa070u,
    0x19a4c116u,0x1e376c08u,0x2748774cu,0x34b0bcb5u,0x391c0cb3u,0x4ed8aa4au,0x5b9cca4fu,0x682e6ff3u,
    0x748f82eeu,0x78a5636fu,0x84c87814u,0x8cc70208u,0x90befffau,0xa4506cebu,0xbef9a3f7u,0xc67178f2u,
};

struct sha256_ctx {
    unsigned int h[8];
    unsigned char buf[64];
    unsigned int buf_len;
    unsigned long long total_len;
};

static unsigned int rotr32(unsigned int x, unsigned int n) {
    return (x >> n) | (x << (32u - n));
}

static void sha256_block(struct sha256_ctx *ctx, const unsigned char *p) {
    unsigned int w[64];
    unsigned int a, b, c, d, e, f, g, h;
    unsigned int i;

    for (i = 0; i < 16; i = i + 1) {
        w[i] = ((unsigned int)p[i * 4] << 24) | ((unsigned int)p[i * 4 + 1] << 16)
             | ((unsigned int)p[i * 4 + 2] << 8) | ((unsigned int)p[i * 4 + 3]);
    }
    for (i = 16; i < 64; i = i + 1) {
        unsigned int s0 = rotr32(w[i - 15], 7) ^ rotr32(w[i - 15], 18) ^ (w[i - 15] >> 3);
        unsigned int s1 = rotr32(w[i - 2], 17) ^ rotr32(w[i - 2], 19) ^ (w[i - 2] >> 10);
        w[i] = w[i - 16] + s0 + w[i - 7] + s1;
    }

    a = ctx->h[0]; b = ctx->h[1]; c = ctx->h[2]; d = ctx->h[3];
    e = ctx->h[4]; f = ctx->h[5]; g = ctx->h[6]; h = ctx->h[7];

    for (i = 0; i < 64; i = i + 1) {
        unsigned int s1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25);
        unsigned int ch = (e & f) ^ ((~e) & g);
        unsigned int temp1 = h + s1 + ch + K[i] + w[i];
        unsigned int s0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22);
        unsigned int maj = (a & b) ^ (a & c) ^ (b & c);
        unsigned int temp2 = s0 + maj;
        h = g; g = f; f = e; e = d + temp1;
        d = c; c = b; b = a; a = temp1 + temp2;
    }

    ctx->h[0] += a; ctx->h[1] += b; ctx->h[2] += c; ctx->h[3] += d;
    ctx->h[4] += e; ctx->h[5] += f; ctx->h[6] += g; ctx->h[7] += h;
}

void sha256_init(struct sha256_ctx *ctx) {
    ctx->h[0] = 0x6a09e667u; ctx->h[1] = 0xbb67ae85u; ctx->h[2] = 0x3c6ef372u; ctx->h[3] = 0xa54ff53au;
    ctx->h[4] = 0x510e527fu; ctx->h[5] = 0x9b05688cu; ctx->h[6] = 0x1f83d9abu; ctx->h[7] = 0x5be0cd19u;
    ctx->buf_len = 0;
    ctx->total_len = 0;
}

void sha256_update(struct sha256_ctx *ctx, const unsigned char *data, unsigned int len) {
    unsigned int i = 0;
    ctx->total_len = ctx->total_len + len;
    if (ctx->buf_len != 0) {
        while (i < len && ctx->buf_len < 64) {
            ctx->buf[ctx->buf_len] = data[i];
            ctx->buf_len = ctx->buf_len + 1;
            i = i + 1;
        }
        if (ctx->buf_len == 64) {
            sha256_block(ctx, ctx->buf);
            ctx->buf_len = 0;
        }
    }
    while (len - i >= 64) {
        sha256_block(ctx, data + i);
        i = i + 64;
    }
    while (i < len) {
        ctx->buf[ctx->buf_len] = data[i];
        ctx->buf_len = ctx->buf_len + 1;
        i = i + 1;
    }
}

void sha256_finalize(struct sha256_ctx *ctx, unsigned char out[32]) {
    unsigned long long bit_len = ctx->total_len * 8ull;
    unsigned char pad = 0x80u;
    int i;

    sha256_update(ctx, &pad, 1);
    {
        unsigned char zero = 0;
        while (ctx->buf_len != 56) {
            sha256_update(ctx, &zero, 1);
        }
    }
    {
        unsigned char lenbuf[8];
        for (i = 0; i < 8; i = i + 1) {
            lenbuf[i] = (unsigned char)(bit_len >> ((7 - i) * 8));
        }
        /* Append directly: buf_len is exactly 56, these 8 bytes fill
         * the block exactly without re-entering sha256_update's own
         * len-accounting (which would double-count the padding). */
        {
            unsigned int j;
            for (j = 0; j < 8; j = j + 1) {
                ctx->buf[ctx->buf_len] = lenbuf[j];
                ctx->buf_len = ctx->buf_len + 1;
            }
        }
        sha256_block(ctx, ctx->buf);
    }

    for (i = 0; i < 8; i = i + 1) {
        out[i * 4] = (unsigned char)(ctx->h[i] >> 24);
        out[i * 4 + 1] = (unsigned char)(ctx->h[i] >> 16);
        out[i * 4 + 2] = (unsigned char)(ctx->h[i] >> 8);
        out[i * 4 + 3] = (unsigned char)(ctx->h[i]);
    }
}
