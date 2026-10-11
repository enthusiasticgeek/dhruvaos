/* Stage-0 A/B kernel-slot loader -- entry point and exception vectors.
 * BCM2835 / Pi 1 Model B (ARM1176JZF-S, ARMv6). Linked at 0x8000 -- the
 * fixed physical address GPU firmware always loads the file named
 * `kernel.img` at (see link.ld). This file now permanently IS that
 * file; the real DhruvaOS kernel moved to 0x00200000 and is loaded by
 * this program, not by firmware directly.
 *
 * Deliberately a near-verbatim copy of boot/rpi1/boot.S's own two
 * hardest-won real-hardware lessons (safe_svcmode_maskall + copying the
 * vector table down to address 0, since ARMv6 has no VBAR) -- stage-0
 * is the one piece of this feature that, if subtly wrong, causes
 * exactly the kind of silent unrecoverable hang this whole feature
 * exists to let the user avoid without a physical card swap. Everything
 * else about boot.S (MMU page tables, per-mode stacks beyond SVC,
 * domain setup) is deliberately NOT replicated -- stage-0 never enables
 * the MMU and never unmasks IRQ/FIQ, so none of that machinery is
 * needed, and every line not needed is a line that can't have a bug.
 */

.section ".vectors", "ax"
.global _start
_start:
    ldr pc, [pc, #24]   /* 0x00: reset */
    ldr pc, [pc, #24]   /* 0x04: undefined instruction */
    ldr pc, [pc, #24]   /* 0x08: software interrupt (SWI/SVC) */
    ldr pc, [pc, #24]   /* 0x0C: prefetch abort */
    ldr pc, [pc, #24]   /* 0x10: data abort */
    ldr pc, [pc, #24]   /* 0x14: reserved */
    ldr pc, [pc, #24]   /* 0x18: IRQ */
    ldr pc, [pc, #24]   /* 0x1C: FIQ */
.word boot_entry
.word stage0_fault   /* undef -- never legitimately reached */
.word stage0_fault   /* SWI -- stage-0 never issues one */
.word stage0_fault   /* prefetch abort */
.word stage0_fault   /* data abort */
.word stage0_fault   /* reserved */
.word stage0_fault   /* IRQ -- never unmasked, so never legitimate */
.word stage0_fault   /* FIQ -- same */

.section ".text.boot"
.global boot_entry
boot_entry:
    /* Force SVC mode, mask IRQ+FIQ -- firmware's handoff state is not
     * guaranteed (see boot.S's own identical fix, task #163). */
    mrs r0, cpsr
    bic r0, r0, #0x1F
    orr r0, r0, #0xD3
    msr cpsr_c, r0

    /* Copy the 16-word vector table down to address 0 -- ARMv6 has no
     * VBAR, hardware only ever reads exceptions from 0x0. */
    ldr r0, =_start
    mov r1, #0
    ldmia r0!, {r2, r3, r4, r5, r6, r7, r8, r9}
    stmia r1!, {r2, r3, r4, r5, r6, r7, r8, r9}
    ldmia r0!, {r2, r3, r4, r5, r6, r7, r8, r9}
    stmia r1!, {r2, r3, r4, r5, r6, r7, r8, r9}

    /* Defensive cache/MMU/TLB/branch-predictor invalidate -- same
     * reasoning as boot.S's own checkpoint 1: don't trust firmware left
     * this core in a clean state at an address range (0x8000 and now
     * also 0x00200000, where the real kernel will shortly be read into
     * RAM) this program is about to reuse. Stage-0 never turns the MMU
     * ON (flat physical addressing throughout -- there is no page
     * table here), this only clears whatever might already be stale. */
    mrc p15, 0, r0, c1, c0, 0
    bic r0, r0, #0x1000
    bic r0, r0, #0x7
    mcr p15, 0, r0, c1, c0, 0
    mov r0, #0
    mcr p15, 0, r0, c7, c7, 0
    mcr p15, 0, r0, c8, c7, 0
    mcr p15, 0, r0, c7, c5, 6
    mcr p15, 0, r0, c7, c10, 4
    mcr p15, 0, r0, c7, c5, 4

    ldr sp, =_stage0_stack_top

    bl stage0_main

    /* stage0_main() never legitimately returns -- it either jumps into
     * the chosen kernel slot directly, or halts after reporting a fatal
     * error. Reaching here is itself a bug; fail loudly rather than
     * execute whatever instructions happen to follow in memory. */
    b stage0_fault_from_asm

.global stage0_fault_from_asm
stage0_fault_from_asm:
    mov r0, #0
    bl stage0_fault
