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
 * the process's whole lifetime.
 *
 * BUG (round 10 audit, 2026-08-27): 64KB was a Phase 1 guess, never
 * tied to any real hardware constraint -- QEMU's raspi1ap model (and
 * the real Pi 1 Model B it emulates) has 512MB of actual RAM; nothing
 * about this bare-metal image needs the heap capped this tight. It
 * quietly crept up over many rounds of self-tests and task-stack
 * growth until round 9's DHCP client (dhcp_self_test alone allocates
 * over a dozen buffers, boot-time-only but never freed like everything
 * else here) pushed measured usage to 65352/65536 bytes -- only 184
 * bytes of margin -- and round 10's own added dhcp_nak_self_test
 * tipped it over: task_e's first scheduled run allocates its own
 * ~1520 bytes of persistent scratch (gc_buf/compact_buf/
 * compact_path_buf/compact_data_buf, see kernel_main.vani), which
 * dhruva_alloc_bytes correctly returned null for once the heap was
 * exhausted -- and that null pointer got written through with no
 * check, corrupting memory and reproducing this project's own
 * previously-documented heap-exhaustion crash signature (PC landing
 * back at _start) via a new path. Found via phase4_milestone.py
 * showing 12 boot banners instead of 1 -- a genuine reboot loop, not
 * the settle-time timing flake this project has hit before. Fixed by
 * actually sizing the heap to the real constraint (there isn't one
 * worth worrying about at this image's scale) instead of continuing
 * to shave bytes off self-test buffers every time a new feature nudges
 * the total over some arbitrary line -- see kernel_main.vani's new
 * heap_usage_self_test for the permanent early-warning check this
 * fix added so a future round hits a loud, graded self-test failure
 * instead of a silent, hard-to-diagnose reboot loop. */
#define DHRUVA_HEAP_BYTES (256 * 1024)
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
/* Memory-safety hardening pass (2026-08-29): dhruva_alloc_bytes
 * returning NULL on exhaustion was never actually a safe contract --
 * see this function's own BUG comment above documenting the exact
 * corruption that happened the one time this project hit it for real
 * (round 10): a caller wrote straight through the returned null with
 * no check, corrupting low memory (the vector table lives at address
 * 0). None of the 218 real call sites across kernel_main.vani check
 * for null today either, and most of them are one-time boot-time
 * scratch-buffer/self-test allocations with no sensible "try again
 * smaller" recovery path anyway -- adding 218 individual null checks
 * would be more code for less robustness than making the ONE place
 * that actually detects exhaustion incapable of handing back an
 * unchecked value at all.
 *
 * This makes exhaustion a loud, diagnosable, immediate halt instead --
 * matching this project's own established "trap, don't corrupt
 * silently" convention already used for checked arithmetic (vani's
 * default +/-/* overflow traps) and hardware faults (boot/rpi1/
 * vectors.S's fault_data_abort/fault_prefetch_abort, boot/rpi4/
 * vectors.S's aarch64_fault_common) -- out-of-memory is exactly the
 * same class of condition: unrecoverable at this layer, and far
 * better surfaced immediately with real diagnostic data than left to
 * manifest later as unexplained corruption. heap_usage_self_test's
 * own boot-time 16KB-headroom canary is the thing that should catch
 * this in practice, every time -- this halt is the backstop for
 * whatever that canary doesn't (a runtime code path allocating far
 * more than boot-time self-tests account for), not the primary
 * defense. Raw MMIO UART output here (not a call into vani) matches
 * boot/rpi1/vectors.S's own fault handlers -- this needs to work even
 * if vani's own generated code is in a state too corrupted to trust
 * calling back into. */
static void dhruva_oom_putc(char c) {
    volatile unsigned int *uart_fr = (volatile unsigned int *)0x20201018;
    volatile unsigned int *uart_dr = (volatile unsigned int *)0x20201000;
    while ((*uart_fr) & 0x20) {
        /* wait while TX FIFO full (FR bit 5) */
    }
    *uart_dr = (unsigned int)(unsigned char)c;
}

static void dhruva_oom_puts(const char *s) {
    while (*s != '\0') {
        dhruva_oom_putc(*s);
        s = s + 1;
    }
}

static void dhruva_oom_put_u64(unsigned long long v) {
    char digits[24];
    int n = 0;
    if (v == 0) {
        dhruva_oom_putc('0');
        return;
    }
    while (v > 0) {
        digits[n] = (char)('0' + (v % 10));
        v = v / 10;
        n = n + 1;
    }
    while (n > 0) {
        n = n - 1;
        dhruva_oom_putc(digits[n]);
    }
}

static void dhruva_oom_fatal(unsigned long requested, unsigned long used) {
    dhruva_oom_puts("\nFATAL: dhruva_alloc_bytes out of memory -- requested ");
    dhruva_oom_put_u64((unsigned long long)requested);
    dhruva_oom_puts(" bytes, ");
    dhruva_oom_put_u64((unsigned long long)used);
    dhruva_oom_puts(" of ");
    dhruva_oom_put_u64((unsigned long long)DHRUVA_HEAP_BYTES);
    dhruva_oom_puts(" already used. Halting -- heap_usage_self_test's own"
                     " boot-time headroom check should have caught this"
                     " before it ever reached here; if it fires here"
                     " instead, some runtime code path is allocating far"
                     " more than boot-time self-tests account for.\n");
    while (1) {
        /* halt -- there is no safe way to continue with a request this
         * function could not satisfy */
    }
}

void *dhruva_alloc_bytes(long n) {
    unsigned long need = (unsigned long)n;
    unsigned long saved_cpsr;
    __asm__ volatile ("mrs %0, cpsr\n\tcpsid i" : "=r"(saved_cpsr) :: "memory");
    unsigned long aligned_used = (dhruva_heap_used + 7UL) & ~7UL;
    if (aligned_used + need > DHRUVA_HEAP_BYTES) {
        unsigned long used_at_failure = dhruva_heap_used;
        __asm__ volatile ("msr cpsr_c, %0" :: "r"(saved_cpsr) : "memory");
        dhruva_oom_fatal(need, used_at_failure);
        /* unreachable -- dhruva_oom_fatal never returns */
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

/* Backs kernel_main.vani's heap_usage_self_test -- a permanent
 * early-warning canary added by the same round-10 fix that resized
 * this heap, so a future round eating back into the new headroom
 * fails loudly at boot instead of reproducing this exact bug again
 * as a silent reboot loop.
 *
 * BUG (round 30 audit, found via live-testing scrutiny of the boot
 * log, not this self-test's own PASS/FAIL count -- the same "read the
 * actual output, don't just trust a name" discipline that caught
 * round 26's ARP-cache bug): this returned plain `long`, which is
 * 32-bit under this target's AAPCS (arm-none-eabi ILP32), but vani's
 * own extern declaration (kernel_main.vani line ~33) says `-> i64`, a
 * genuine 64-bit return. AAPCS returns a 64-bit value in the r0:r1
 * register pair; a 32-bit `long` return only ever populates r0,
 * leaving r1 as whatever was left over from a prior call. Every
 * caller reading this as a real i64 got a huge, non-deterministic
 * garbage value in the high 32 bits (heap_usage_self_test's own boot
 * print showed something like "used=572811198400528" instead of the
 * real, entirely reasonable ~67600) -- silently printing "(FAIL,
 * expect headroom >= 16384)" at every single boot since this function
 * was introduced (round 10), never noticed because attention went to
 * self-tests' PASS/FAIL counts, not this one line's own literal text.
 * Fixed by actually returning a 64-bit value end to end, matching
 * vani's declared i64 rather than silently truncating across the FFI
 * boundary. */
long long dhruva_heap_used_bytes(void) {
    return (long long)dhruva_heap_used;
}

/* dev==2 block-device backend is host-harness-only (see kernel_main.
 * vani's own comment on dharafs_block_read/dharafs_block_write and
 * host_virtual_disk_read/write) -- dharafs_state_get_block_dev() is
 * never set to 2 anywhere in real bare-metal code, so these two
 * symbols exist purely to satisfy the linker and should never
 * actually be called on real hardware. Return -1 (the same "I/O
 * error" convention sdhost_read_block/write_block and usb_msd_
 * read10/write10 already use) rather than silently succeeding or
 * touching real memory, so that if this ever *did* get reached via
 * some future bug, it fails loudly instead of pretending to work. */
long long host_virtual_disk_read(long long block_num, void *buf) {
    (void)block_num;
    (void)buf;
    return -1;
}

long long host_virtual_disk_write(long long block_num, void *buf) {
    (void)block_num;
    (void)buf;
    return -1;
}
