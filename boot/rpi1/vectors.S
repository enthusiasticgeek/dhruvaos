/* Dhruva Phase 2 -- ARM exception vector table (Pi 1 / ARM1176, ARMv6).
 *
 * ARMv6 has no VBAR (that's an ARMv7+ addition) -- the vector table
 * location is fixed at either 0x00000000 (low vectors, the reset
 * default) or 0xFFFF0000 (high vectors). This uses low vectors, but
 * TASK #163 FIX (first real-hardware boot, 2026-09-12): this table is
 * no longer LINKED at address 0 directly. It used to be, and that
 * worked fine under QEMU's own `-kernel` ELF loader (which places
 * each of an ELF's segments at its own independent address) -- but
 * real Pi firmware loads `kernel.img` as ONE flat raw binary at a
 * single fixed address (0x8000), with no way to also place a second,
 * disjoint region at address 0. This table is now linked AT 0x8000
 * instead -- the real entry point, where firmware both loads AND
 * jumps on real hardware -- immediately followed by the real boot
 * code (boot.S's own `boot_entry`, not `_start` anymore: `_start` is
 * THIS table now, matching the real firmware's own idea of where
 * the kernel begins). `boot_entry`'s own first action explicitly
 * copies this table down to address 0 at runtime, since that's where
 * the CPU's own hardware actually reads exception vectors from, but
 * is NOT an address real firmware can be told to load a plain raw-
 * binary kernel.img at. See link.ld's own comment (`.vectors` output
 * section) for the full reasoning, confirmed directly against
 * dwelch67/raspberrypi's own well-known, proven blinker05 example.
 *
 * This is genuinely board/architecture-specific, not just BCM2835-
 * specific -- PandaBoard's Cortex-A9 is ARMv7-A and *does* have VBAR,
 * so it gets to relocate its vector table wherever convenient instead
 * of fighting over address 0. A PandaBoard port needs its own version
 * of this file, not a shared one.
 *
 * Classic ARM vector-table trick: every entry is `ldr pc, [pc, #24]`,
 * which -- because of ARM's pipeline, PC reads as (this instruction's
 * address + 8) -- loads from a literal pool placed immediately after
 * the 8 vector instructions (8*4 = 32 = 0x20 bytes further on; #24
 * plus the implicit +8 = 0x20). Every vector uses the identical
 * encoding; only the corresponding literal-pool word differs.
 */

.section ".vectors", "ax"
.global _start
.global _vectors
_start:
_vectors:
    ldr pc, [pc, #24]   /* 0x00: reset */
    ldr pc, [pc, #24]   /* 0x04: undefined instruction */
    ldr pc, [pc, #24]   /* 0x08: software interrupt (SWI/SVC) */
    ldr pc, [pc, #24]   /* 0x0C: prefetch abort */
    ldr pc, [pc, #24]   /* 0x10: data abort */
    ldr pc, [pc, #24]   /* 0x14: reserved */
    ldr pc, [pc, #24]   /* 0x18: IRQ */
    ldr pc, [pc, #24]   /* 0x1C: FIQ */
.word boot_entry
.word fault_undef
.word fault_swi
.word fault_prefetch_abort
.word fault_data_abort
.word fault_reserved
.word irq_entry
.word fault_fiq

/* Phase 2 doesn't recover from most of these -- just halts, so a real
 * bug shows up as "the board stopped," not as running on into
 * corrupted state. undef/swi/reserved/fiq still have no UART
 * diagnostic; not required for anything built so far.
 *
 * Round 38: fault_data_abort/fault_prefetch_abort get a real
 * diagnostic instead -- MMU permission faults (this round's own W^X
 * enforcement) are now a genuinely expected event, not an
 * unrecoverable bug, and a silent `b .` would make debugging any real
 * page-table mistake here effectively impossible (no JTAG on this
 * project's QEMU target). Neither handler ever returns -- both halt
 * forever after printing, same as every other fault here -- so
 * there's no need to preserve/restore any register state, only to
 * read the fault info before it's gone and report it.
 *
 * DFAR/DFSR (data) and IFAR/IFSR (prefetch) are read here, in Abort
 * mode, BEFORE switching to SVC mode with `cps` -- the exact same
 * proven pattern irq_entry.S already uses to reach vani code safely
 * (Abort mode's own banked sp only needs to survive these few MRC
 * reads, never a real push, so _abort_stack_top's 4KB is generous
 * headroom, not a tight fit). IFAR is an ARMv6 addition (ARM1176JZF-S
 * implements it) -- confirmed empirically as part of this round's own
 * live verification, not just assumed from architecture docs alone,
 * since QEMU's own source wasn't available to cross-check against
 * this time (unlike every other peripheral in this project). */
.global fault_undef
.global fault_swi
.global fault_reserved
.global fault_fiq
fault_undef:
fault_swi:
fault_reserved:
fault_fiq:
    b .

.global fault_data_abort
fault_data_abort:
    /* Round 62c crash investigation (task #154): r0-r3 are NOT banked
     * in Abort mode -- they're still exactly the faulting instruction's
     * own live operand registers at entry here -- but the two `mrc`
     * reads below are about to overwrite r0/r1, and DFAR/DFSR/fault_pc
     * need r0-r2 for abort_report_data's existing 3 args. Stash the
     * ORIGINAL r0-r3 into r4-r7 first (never banked/touched by anything
     * below until the explicit stack spill), so a faulting `str rD,
     * [rN, rM]`-shaped instruction's actual base/offset register
     * VALUES can be reported too, not just the fault address -- the
     * open question this round is stuck on is exactly "was the base
     * pointer really 0, or something else," which DFAR alone can't
     * distinguish from e.g. a corrupted offset added to a valid base. */
    mov r4, r0
    mov r5, r1
    mov r6, r2
    mov r7, r3
    mrc p15, 0, r0, c6, c0, 0   /* DFAR: data fault address */
    mrc p15, 0, r1, c5, c0, 0   /* DFSR: data fault status */
    /* Round 60 crash investigation: lr_abt (data abort convention) =
     * address of the aborting instruction + 8 -- capture it as r2
     * BEFORE the mode switch below, since lr is banked per-mode and
     * this value would otherwise be gone the instant SVC mode's own
     * lr_svc becomes current. */
    sub r2, lr, #8
    mov r3, r4                  /* orig_r0 -> arg4 */
    cps #0x13                   /* SVC mode -- never returning, safe to
                                  * reuse whatever's on that stack */
    /* Round 68: lr is banked per-mode, so the instant we're in SVC
     * mode, "lr" transparently means lr_svc -- whatever the SVC-mode
     * code (i.e. the faulting function's own caller) last set it to
     * via its own `bl`, completely untouched by taking this exception
     * (that only ever affects lr_abt, a physically different
     * register). For every crash this investigation has actually
     * hit, the fault happens on buf_read_u32/buf_write_u32's own
     * FIRST instruction (a 2-instruction leaf: `ldr r0,[r0,r1]; bx
     * lr`) -- so lr_svc here is exactly that function's own return
     * address, i.e. the real call site that invoked it with a bad
     * pointer, addr2line-able like any other address. r8 is safe
     * scratch (unused anywhere else in this handler, not yet spilled
     * to the stack below). Captured here, before `bl
     * abort_report_data` below overwrites lr with ITS OWN return
     * address. */
    mov r8, lr
    sub sp, sp, #16
    str r5, [sp, #0]            /* orig_r1 -> arg5 (stack) */
    str r6, [sp, #4]            /* orig_r2 -> arg6 (stack) */
    str r7, [sp, #8]            /* orig_r3 -> arg7 (stack) */
    str r8, [sp, #12]           /* orig_lr -> arg8 (stack) */
    bl abort_report_data
    b .

.global fault_prefetch_abort
fault_prefetch_abort:
    mrc p15, 0, r0, c6, c0, 2   /* IFAR: instruction fault address */
    mrc p15, 0, r1, c5, c0, 1   /* IFSR: instruction fault status */
    cps #0x13
    bl abort_report_prefetch
    b .
