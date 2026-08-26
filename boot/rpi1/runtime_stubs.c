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
 * Returns a genuine pointer -- corrected 2026-08-25. Earlier versions
 * returned a plain `long` out of a wrong assumption that vani's extern
 * "C" FFI couldn't carry raw pointer types across the boundary at all;
 * disproven by testing the actual LLVM IR, where `mut ref i64` lowers to
 * plain `i64*`, exactly the pointer-sized ABI slot this function's
 * result was already occupying either way. `void*` is the honest C-side
 * type for what this actually is now that the vani side calls it what
 * it is instead of routing it through a same-width integer.
 *
 * Deliberately a bump allocator, never freed -- matches the
 * architecture doc's Phase 1 call for a fixed-block allocator, not a
 * general heap: task stacks are allocated once at boot and live for
 * the process's whole lifetime. */
#define DHRUVA_HEAP_BYTES (64 * 1024)
static unsigned char dhruva_heap[DHRUVA_HEAP_BYTES];
static unsigned long dhruva_heap_used = 0;

void *dhruva_alloc_bytes(long n) {
    unsigned long need = (unsigned long)n;
    unsigned long aligned_used = (dhruva_heap_used + 7UL) & ~7UL;
    if (aligned_used + need > DHRUVA_HEAP_BYTES) {
        return (void*)0; /* out of kernel heap -- caller must check for null */
    }
    unsigned char *p = dhruva_heap + aligned_used;
    unsigned long i = 0;
    while (i < need) {
        p[i] = 0;
        i = i + 1;
    }
    dhruva_heap_used = aligned_used + need;
    return (void*)p;
}
