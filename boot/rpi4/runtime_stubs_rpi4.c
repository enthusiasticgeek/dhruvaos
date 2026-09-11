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
 * Smaller than boot/rpi1/runtime_stubs.c in one respect: no libgcc
 * divide helper needed (AArch64 has a hardware SDIV/UDIV, unlike
 * ARMv6). Round 179 added a heap allocator (dhruva_alloc_bytes_rpi4
 * and friends, below) ported from that same file's own design -- see
 * that section's own comment for the one real AArch64-vs-ARM32
 * porting difference (DAIF vs. CPSR for the critical section) and why
 * this board didn't have one until now.
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

/* Round 179: heap allocator, ported from boot/rpi1/runtime_stubs.c's
 * own dhruva_alloc_bytes -- a plain bump allocator (no free) over a
 * static backing array, 8-byte-aligned, halting on exhaustion rather
 * than returning null (matching that file's own reasoning: every
 * caller in this codebase assumes allocation cannot fail, so a null
 * return would just move the crash to a less diagnosable spot).
 * Motivated directly by round 166's 512-byte-array-cap style: without
 * a heap, every buffer on this board has to be a fixed-size [T; N]
 * sized for the worst case up front (TLS's own 512-byte cap, well
 * under Pi 1's real 2048-byte record size, is exactly this
 * constraint) -- a heap removes that ceiling.
 *
 * Only real porting difference from the ARM32 original: AArch64 has
 * no CPSR/`cpsid`. The DAIF register's bit 1 (0x2) is the IRQ mask,
 * set with `msr daifset, #2` and restored by writing the whole
 * register back with `msr daif, %0` -- same "always leave interrupts
 * exactly as this function found them" critical-section shape, just
 * AArch64's own instructions for it. No stack-guard-page variant yet
 * (Pi 1's dhruva_alloc_stack_guarded) -- this board's MMU
 * (boot/rpi4/mmu_init.S) only has 2MB block descriptors so far, no
 * 4KB page-table level to install a guard page into; tracked
 * separately (task #178) as a real new MMU capability, not just a
 * port of this function. */
#define DHRUVA_HEAP_BYTES_RPI4 (768 * 1024)
static unsigned char dhruva_heap_rpi4[DHRUVA_HEAP_BYTES_RPI4];
static unsigned long dhruva_heap_used_rpi4 = 0;
static unsigned long dhruva_alloc_count_rpi4 = 0;

static void dhruva_oom_fatal_rpi4(unsigned long requested, unsigned long used) {
    __asm__ volatile ("msr daifset, #2" ::: "memory");
    dhruva_dprintf_puts_rpi4("\nFATAL: dhruva_alloc_bytes out of memory -- requested ");
    dhruva_dprintf_put_i64_rpi4((long long)requested);
    dhruva_dprintf_puts_rpi4(" bytes, ");
    dhruva_dprintf_put_i64_rpi4((long long)used);
    dhruva_dprintf_puts_rpi4(" of ");
    dhruva_dprintf_put_i64_rpi4((long long)DHRUVA_HEAP_BYTES_RPI4);
    dhruva_dprintf_puts_rpi4(" already used. Halting -- heap_usage_self_test_rpi4's own"
                              " boot-time headroom check should have caught this before"
                              " it ever reached here.\n");
    while (1) {
        /* halt -- there is no safe way to continue with a request this
         * function could not satisfy */
    }
}

long long dhruva_alloc_count_get_rpi4(void) {
    return (long long)dhruva_alloc_count_rpi4;
}

long long dhruva_heap_used_bytes_rpi4(void) {
    return (long long)dhruva_heap_used_rpi4;
}

/* Round 179: raw byte read/write through a heap pointer, the AArch64
 * twin of boot/dharafs_buf.S's own buf_read_byte/buf_write_byte
 * (ARM32 assembly, `strb`/`ldrb`) -- trivial enough to write directly
 * in C here rather than a new AArch64 assembly file, same as this
 * file's own memcpy/strlen stubs above. `buf` is a raw pointer
 * (vani's `mut ref i64` calling convention for heap-pointer-style
 * APIs, matching kernel_main.vani's own dhruva_alloc_bytes callers).
 */
unsigned int buf_write_byte(unsigned char *buf, unsigned int offset, unsigned int value) {
    buf[offset] = (unsigned char)value;
    return 0;
}

unsigned int buf_read_byte(unsigned char *buf, unsigned int offset) {
    return (unsigned int)buf[offset];
}

void *dhruva_alloc_bytes_rpi4(long n) {
    unsigned long need = (unsigned long)n;
    unsigned long saved_daif;
    __asm__ volatile ("mrs %0, daif\n\tmsr daifset, #2" : "=r"(saved_daif) :: "memory");

    unsigned long aligned_used = (dhruva_heap_used_rpi4 + 7UL) & ~7UL;
    if (aligned_used + need > DHRUVA_HEAP_BYTES_RPI4) {
        unsigned long used_at_failure = dhruva_heap_used_rpi4;
        dhruva_oom_fatal_rpi4(need, used_at_failure);
        /* unreachable -- dhruva_oom_fatal_rpi4 never returns */
    }
    unsigned char *p = dhruva_heap_rpi4 + aligned_used;
    dhruva_heap_used_rpi4 = aligned_used + need;
    dhruva_alloc_count_rpi4 = dhruva_alloc_count_rpi4 + 1;
    __asm__ volatile ("msr daif, %0" :: "r"(saved_daif) : "memory");
    unsigned long i = 0;
    while (i < need) {
        p[i] = 0;
        i = i + 1;
    }
    return (void*)p;
}
