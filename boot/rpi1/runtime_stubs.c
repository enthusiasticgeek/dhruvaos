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

/* Phase 4 task #10 -- pulled in transitively: linking -lgcc for
 * __aeabi_ldivmod (ARMv6 has no hardware integer divide, needed once
 * the expression evaluator started dividing i64s) drags in libgcc's
 * unwind-arm.o as a side effect of static-archive linking granularity,
 * which references memcpy from its (dead-code-for-us) exception-
 * propagation path. Same category as strlen/dprintf/exit above: a
 * hosted-libc assumption baked into code we didn't write, not
 * something to route around. */
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

/* BUG (Phase 4 task #9, found via a real crash-and-reboot loop only
 * visible under an event-driven interactive test, not a sleep-timed
 * one -- see test/shell_interactive_check.py's header): this bump
 * pointer's read-modify-write of dhruva_heap_used had no locking at
 * all. Harmless for as long as only one preemptible task ever called
 * this at real runtime (task_e/GC, Phase 3) -- every other caller was
 * kernel_main's own single-threaded setup, before start_multitasking
 * hands off to the scheduler. Once task_f (the shell) became a SECOND
 * independently-scheduled task that also calls this during normal
 * multitasking, the two could race: the timer tick can preempt this
 * function between reading dhruva_heap_used and writing its updated
 * value back, and if the task it switches to also calls this before
 * the first one resumes, both compute the same `aligned_used` and get
 * back OVERLAPPING pointers into the same heap region -- silent
 * corruption the instant either side writes through its "own" buffer,
 * observed as sporadic crashes (PC landing back at _start, the same
 * signature as every other memory-corruption bug this project has
 * hit) a few shell commands into a session, once GC's periodic wake
 * finally landed inside this window. Single-core bare metal, so a
 * short IRQ-disable around just the bookkeeping (not the zero-fill,
 * which only ever touches this call's own now-exclusive region) is
 * sufficient -- no real critical-section primitive needed.
 *
 * SECOND BUG in the first fix attempt: unconditionally re-enabling
 * IRQs (`cpsie i`) on the way out silently broke kernel_main's own
 * boot-time invariant that interrupts stay masked for the whole of
 * its single-threaded setup, only turning on via start_multitasking's
 * own deliberate final CPSR restore. kernel_main calls this function
 * many times during that setup (sd_buf, task stacks, ...), so the
 * very first call would have flipped IRQs on early -- long before
 * start_multitasking had finished writing sp_table/eff_prio_table/
 * current_task -- letting the timer tick (and, once uart_rx_irq_init
 * ran, UART RX too) preempt into a scheduler with half-built state.
 * Exactly the kind of bug that looks like pure flakiness: sometimes
 * the race window is missed and everything looks fine, sometimes it
 * corrupts scheduling and the whole system goes silent forever. Save
 * and restore the real prior state instead of forcing it back on. */
void *dhruva_alloc_bytes(long n) {
    unsigned long need = (unsigned long)n;
    unsigned long saved_cpsr;
    __asm__ volatile ("mrs %0, cpsr\n\tcpsid i" : "=r"(saved_cpsr) :: "memory");
    unsigned long aligned_used = (dhruva_heap_used + 7UL) & ~7UL;
    if (aligned_used + need > DHRUVA_HEAP_BYTES) {
        __asm__ volatile ("msr cpsr_c, %0" :: "r"(saved_cpsr) : "memory");
        return (void*)0; /* out of kernel heap -- caller must check for null */
    }
    unsigned char *p = dhruva_heap + aligned_used;
    dhruva_heap_used = aligned_used + need;
    __asm__ volatile ("msr cpsr_c, %0" :: "r"(saved_cpsr) : "memory");
    unsigned long i = 0;
    while (i < need) {
        p[i] = 0;
        i = i + 1;
    }
    return (void*)p;
}
