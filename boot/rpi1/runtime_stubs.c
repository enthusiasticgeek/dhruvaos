/* Dhruva Phase 0 -- minimal freestanding C-ABI runtime stubs.
 *
 * Not driver or OS code -- glue satisfying an assumption baked into
 * vani's own generated runtime-support code, which expects a hosted
 * libc underneath it: str_len_bytes() calls strlen(), and the
 * compiler-inserted bounds-check panic path (__intent_trap) calls
 * dprintf()+exit(). On a target with no libc at all, those three
 * symbols must exist or nothing links -- same category of unavoidable
 * exception as boot.S, not a "from scratch in vani" violation, since
 * vani itself can't express a C-ABI varargs function.
 */

typedef unsigned long size_t;

size_t strlen(const char *s) {
    size_t n = 0;
    while (s[n] != '\0') {
        n = n + 1;
    }
    return n;
}

int dprintf(int fd, const char *fmt, ...) {
    (void)fd;
    (void)fmt;
    /* Nothing routes this to the UART yet -- Phase 0's own uart_puts
     * already covers real output, and nothing in Phase 0 should ever
     * hit the bounds-check panic path this backs. Revisit once the
     * panic handler (kernel/panic.vani, per the architecture doc) exists. */
    return 0;
}

void exit(int code) {
    (void)code;
    while (1) {
        /* halt -- there is no OS to return to */
    }
}

/* Dhruva Phase 1 -- minimal bump allocator for task stacks.
 *
 * Returns a raw address as a plain integer rather than a typed pointer
 * on purpose: vani's extern "C" FFI (v1) only supports scalars (i64/f64/
 * bool), Str, and ref T across the boundary -- raw pointer types like
 * *mut i64 are explicitly rejected ("not yet wired through the v1 FFI
 * ABI", confirmed empirically). Since every consumer of this address is
 * hand-written assembly that only ever treats it as an opaque 32-bit
 * word anyway, returning i64 and letting vani pass it straight through
 * is both the only option the FFI allows and the natural fit.
 *
 * Deliberately a bump allocator, never freed -- matches the
 * architecture doc's Phase 1 call for a fixed-block allocator, not a
 * general heap: task stacks are allocated once at boot and live for
 * the process's whole lifetime. */
#define DHRUVA_HEAP_BYTES (64 * 1024)
static unsigned char dhruva_heap[DHRUVA_HEAP_BYTES];
static unsigned long dhruva_heap_used = 0;

long dhruva_alloc_bytes(long n) {
    unsigned long need = (unsigned long)n;
    unsigned long aligned_used = (dhruva_heap_used + 7UL) & ~7UL;
    if (aligned_used + need > DHRUVA_HEAP_BYTES) {
        return 0; /* out of kernel heap -- caller must check for 0 */
    }
    unsigned char *p = dhruva_heap + aligned_used;
    unsigned long i = 0;
    while (i < need) {
        p[i] = 0;
        i = i + 1;
    }
    dhruva_heap_used = aligned_used + need;
    return (long)p;
}
