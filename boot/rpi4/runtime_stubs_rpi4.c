/* Dhruva round 74 -- minimal freestanding C-ABI runtime stubs for the
 * Pi 4/5 (AArch64) vani-compiled kernel piece (kernel/
 * kernel_main_rpi4.vani), the exact AArch64 twin of boot/rpi1/
 * runtime_stubs.c: not driver or OS code, just glue satisfying an
 * assumption baked into vani's own generated runtime-support code,
 * which unconditionally assumes a hosted libc underneath it
 * regardless of whether the vani program itself ever calls these
 * (str_len_bytes() calls strlen(); the compiler-inserted bounds-check
 * panic path calls dprintf()+exit()) -- see build_rpi4.sh's own
 * comment for the full "why", identical to build.sh's Pi 1 rationale.
 *
 * Deliberately smaller than boot/rpi1/runtime_stubs.c: no libgcc
 * divide helper needed (AArch64 has a hardware SDIV/UDIV, unlike
 * ARMv6), and no heap allocator / OOM path yet (kernel_main_rpi4.vani
 * has no dhruva_alloc_bytes call at all -- see that file's own header
 * comment on keeping this round's scope to exactly proving the
 * toolchain, nothing more).
 */

typedef unsigned long size_t;

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n] != '\0') {
        n = n + 1;
    }
    return n;
}

void *memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char*)dst;
    const unsigned char *s = (const unsigned char*)src;
    size_t i = 0;
    while (i < n) {
        d[i] = s[i];
        i = i + 1;
    }
    return dst;
}

/* Raw MMIO UART output for the panic path -- same PL011
 * register/protocol boot/rpi4/boot.S's own uart_puts_rpi4 already
 * uses, at the BCM2711 low-peripheral-mode base (0xFE201000, NOT
 * kernel_main.vani's Pi-1-side 0x20201000) -- needs to work even if
 * vani's own generated code is in a state too corrupted to trust
 * calling back into, matching boot/rpi1/runtime_stubs.c's identical
 * reasoning for the ARMv6 target. */
static void dhruva_dprintf_putc_rpi4(char c) {
    volatile unsigned int *uart_fr = (volatile unsigned int *)0xFE201018;
    volatile unsigned int *uart_dr = (volatile unsigned int *)0xFE201000;
    while ((*uart_fr) & 0x20) {
        /* wait while TX FIFO full (FR bit 5) */
    }
    *uart_dr = (unsigned int)(unsigned char)c;
}

static void dhruva_dprintf_puts_rpi4(const char *s) {
    while (*s != '\0') {
        dhruva_dprintf_putc_rpi4(*s);
        s = s + 1;
    }
}

static void dhruva_dprintf_put_i64_rpi4(long long v) {
    char digits[24];
    int n = 0;
    unsigned long long uv;
    if (v < 0) {
        dhruva_dprintf_putc_rpi4('-');
        uv = (unsigned long long)(-v);
    } else {
        uv = (unsigned long long)v;
    }
    if (uv == 0) {
        dhruva_dprintf_putc_rpi4('0');
        return;
    }
    while (uv > 0) {
        digits[n] = (char)('0' + (uv % 10));
        uv = uv / 10;
        n = n + 1;
    }
    while (n > 0) {
        n = n - 1;
        dhruva_dprintf_putc_rpi4(digits[n]);
    }
}

/* Same two call shapes as boot/rpi1/runtime_stubs.c's own dprintf
 * (__intent_trap's fixed pre-formatted message, intent_assert_fail's
 * single %s) -- see that file's own comment for the full history of
 * why this exists at all (round 61's "long-running computation stalls
 * permanently" investigation, which found the ORIGINAL Pi 1 stub was
 * a total no-op). Not copying that bug here: this is a genuine
 * implementation from the start. */
int dprintf(int fd, const char *fmt, ...) {
    (void)fd;
    __builtin_va_list ap;
    __builtin_va_start(ap, fmt);
    while (*fmt != '\0') {
        if (*fmt == '%' && *(fmt + 1) != '\0') {
            fmt = fmt + 1;
            if (*fmt == 's') {
                const char *s = __builtin_va_arg(ap, const char *);
                dhruva_dprintf_puts_rpi4(s);
            } else if (*fmt == 'd' || *fmt == 'l') {
                while (*fmt == 'l') {
                    fmt = fmt + 1;
                }
                long long v = __builtin_va_arg(ap, long long);
                dhruva_dprintf_put_i64_rpi4(v);
            } else {
                dhruva_dprintf_putc_rpi4('%');
                dhruva_dprintf_putc_rpi4(*fmt);
            }
        } else {
            dhruva_dprintf_putc_rpi4(*fmt);
        }
        fmt = fmt + 1;
    }
    __builtin_va_end(ap);
    return 0;
}

void exit(int code) {
    (void)code;
    while (1) {
        /* halt -- there is no OS to return to */
    }
}
