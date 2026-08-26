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
