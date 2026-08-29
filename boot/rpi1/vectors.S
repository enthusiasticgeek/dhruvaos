/* Dhruva Phase 2 -- ARM exception vector table (Pi 1 / ARM1176, ARMv6).
 *
 * ARMv6 has no VBAR (that's an ARMv7+ addition) -- the vector table
 * location is fixed at either 0x00000000 (low vectors, the reset
 * default) or 0xFFFF0000 (high vectors). This uses low vectors, so
 * this section is placed at address 0 by the linker script, entirely
 * separate from the main image at 0x8000 that boot.S's _start lives
 * in: QEMU's -kernel loader jumps straight to 0x8000 at boot and never
 * touches address 0 unless an actual exception occurs, so both live in
 * the same physical RAM without conflict.
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
.global _vectors
_vectors:
    ldr pc, [pc, #24]   /* 0x00: reset */
    ldr pc, [pc, #24]   /* 0x04: undefined instruction */
    ldr pc, [pc, #24]   /* 0x08: software interrupt (SWI/SVC) */
    ldr pc, [pc, #24]   /* 0x0C: prefetch abort */
    ldr pc, [pc, #24]   /* 0x10: data abort */
    ldr pc, [pc, #24]   /* 0x14: reserved */
    ldr pc, [pc, #24]   /* 0x18: IRQ */
    ldr pc, [pc, #24]   /* 0x1C: FIQ */
.word _start
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
    mrc p15, 0, r0, c6, c0, 0   /* DFAR: data fault address */
    mrc p15, 0, r1, c5, c0, 0   /* DFSR: data fault status */
    cps #0x13                   /* SVC mode -- never returning, safe to
                                  * reuse whatever's on that stack */
    bl abort_report_data
    b .

.global fault_prefetch_abort
fault_prefetch_abort:
    mrc p15, 0, r0, c6, c0, 2   /* IFAR: instruction fault address */
    mrc p15, 0, r1, c5, c0, 1   /* IFSR: instruction fault status */
    cps #0x13
    bl abort_report_prefetch
    b .
