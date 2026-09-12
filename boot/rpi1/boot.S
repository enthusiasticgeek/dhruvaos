/* Dhruva Phase 0/2 boot code -- BCM2835 / Pi 1 Model B (ARM1176JZF-S, ARMv6).
 * QEMU's raspi1ap machine model loads this ELF directly via -kernel and
 * jumps to _start with SVC mode, interrupts masked, MMU/caches off --
 * the same state real BCM2835 firmware leaves the ARM core in after it
 * releases reset.
 *
 * ARMv6 has no `wfe`/`wfi` in the form later cores use, so the halt loop
 * below is a plain branch, not a low-power wait -- correctness first,
 * power-awareness is Phase 5's job, not boot code's.
 *
 * Phase 2 addition: give IRQ mode its own banked stack pointer before
 * anything else runs. ARM IRQ mode has separate banked r13(sp)/r14(lr)
 * from every other mode, so entering IRQ mode with sp_irq still zero
 * (its reset-time value) would corrupt memory at address 0 -- exactly
 * where the vector table lives -- the instant the first interrupt
 * arrives. Interrupts stay globally masked (the CPSR I-bit, untouched
 * here) until kernel_main explicitly unmasks them after the timer/
 * interrupt-controller setup in vani completes; this only prepares the
 * stack IRQ mode will use once that happens. */
/* TEMPORARY, for this round's own real-hardware boot-progress
 * diagnostic only -- blinks the ACT LED (GPIO16 on the original Pi 1
 * Model B, active-low) N times, using ONLY raw GPIO register writes
 * and a busy-wait delay, no UART/vani/anything else that could itself
 * be broken. Placed at checkpoints through early boot so a human
 * watching the LED can tell exactly how far execution actually gets,
 * independent of the UART channel this round's own investigation has
 * so far been unable to get a clear signal through. Removed once real
 * hardware boot is confirmed working (or once this narrows down where
 * it isn't). Uses r8-r12 as scratch -- none of _start's own code uses
 * those registers, so this can't clobber anything the surrounding
 * boot sequence still needs. */
.macro BLINK_N n
    mov r8, #\n
1:
    cmp r8, #0
    beq 2f
    ldr r9, =0x20200028         /* GPCLR0 */
    mov r10, #0x10000           /* GPIO16 */
    str r10, [r9]               /* LED ON (active-low) */
    ldr r11, =80000000
3:
    subs r11, r11, #1
    bne 3b
    ldr r9, =0x2020001C         /* GPSET0 */
    str r10, [r9]               /* LED OFF */
    ldr r11, =80000000
4:
    subs r11, r11, #1
    bne 4b
    subs r8, r8, #1
    b 1b
2:
    ldr r11, =200000000         /* gap between blink groups */
5:
    subs r11, r11, #1
    bne 5b
.endm

.section ".text.boot"
.global _start

_start:
    /* One-time GPIO16 output setup for the diagnostic above. */
    ldr r9, =0x20200004         /* GPFSEL1 (GPIO10-19) */
    ldr r10, [r9]
    bic r10, r10, #(7 << 18)    /* GPIO16's own 3-bit field */
    orr r10, r10, #(1 << 18)    /* set OUTPUT */
    str r10, [r9]
    /* Task #163 (first real-hardware boot, 2026-09-12): force a known-
     * clean cache/MMU/TLB/branch-predictor state before ANYTHING else
     * runs, including before the stack pointer is even set up below.
     *
     * This file's own header comment above claims real BCM2835
     * firmware hands off in "the same state" QEMU's raspi1ap model
     * does -- MMU/caches off. That is the standard, widely-assumed
     * convention, but "assumed" is exactly the word: every line in
     * this entire project has only ever executed under QEMU until
     * this task, which starts the emulated core from a genuinely
     * clean slate every single run by construction, and so could
     * never have caught a handoff-state mismatch even if one existed.
     * Every serious bare-metal ARM1176/ARMv6 bring-up guide treats
     * "don't trust the handoff state, force it clean yourself" as
     * mandatory boilerplate for exactly this reason -- real GPU
     * firmware's own ARM-core-touching code (voltage/clock setup,
     * security checks) is undocumented and can plausibly leave
     * caches/MMU/TLB/branch-predictor populated with stale entries
     * from ITS OWN execution, at physical addresses this kernel is
     * about to reuse for its own code and data.
     *
     * A stale I-cache entry at this kernel's own load address
     * (0x8000) would silently fetch WRONG instructions with no fault,
     * no diagnostic, and no way to ever reach uart_init() to report
     * anything -- indistinguishable from a hang. This is the leading
     * suspect for exactly that symptom on first real boot: the GPU's
     * own firmware demonstrably DOES read this kernel off the SD card
     * correctly (confirmed live via the ACT LED's own real SD-access
     * blink pattern), yet zero UART output was ever observed across
     * multiple verified-good adapters and multiple careful, freshly-
     * timed capture attempts -- a clean hang before uart_init() ever
     * runs fits that evidence exactly, and this exact class of bug is
     * invisible under QEMU by construction, never something this
     * project's own testing history could have exercised before now.
     *
     * r0 is free to clobber here (nothing meaningful in it yet). */
    mrc p15, 0, r0, c1, c0, 0   /* read SCTLR */
    bic r0, r0, #0x1000         /* clear I (icache enable) -- not
                                 * encodable as one immediate together
                                 * with the M/A/C bits below (ARM's
                                 * 8-bit-rotated immediate encoding
                                 * can't express both groups at once),
                                 * hence two bic instructions */
    bic r0, r0, #0x7            /* clear M (MMU), A (alignment fault
                                 * checking), C (dcache enable) */
    mcr p15, 0, r0, c1, c0, 0   /* write SCTLR back */
    mov r0, #0
    mcr p15, 0, r0, c7, c7, 0   /* invalidate I+D cache (ARMv6's
                                 * combined "Invalidate Both Caches") */
    mcr p15, 0, r0, c8, c7, 0   /* invalidate unified TLB */
    mcr p15, 0, r0, c7, c5, 6   /* invalidate branch predictor array */
    mcr p15, 0, r0, c7, c10, 4  /* data synchronization barrier */
    mcr p15, 0, r0, c7, c5, 4   /* flush prefetch buffer (ARMv6's own
                                 * instruction-barrier equivalent --
                                 * ARMv6 has no dedicated `isb`) */

    BLINK_N 1   /* checkpoint 1: cache/MMU/TLB invalidation done */

    ldr sp, =_stack_top

    mrs r0, cpsr
    bic r1, r0, #0x1F
    orr r1, r1, #0x12      /* IRQ mode */
    msr cpsr_c, r1
    ldr sp, =_irq_stack_top
    bic r1, r0, #0x1F
    orr r1, r1, #0x17      /* Round 38: Abort mode -- same reasoning as
                             * IRQ above: entering Abort mode with sp_abt
                             * still at its reset-time value (likely 0,
                             * corrupting the vector table the instant a
                             * Data/Prefetch Abort fires) was harmless
                             * only because nothing before this round
                             * ever gave the CPU a reason to actually
                             * take one. This round's MMU work makes
                             * permission faults a real, expected event. */
    msr cpsr_c, r1
    ldr sp, =_abort_stack_top
    bic r1, r0, #0x1F
    orr r1, r1, #0x13      /* back to SVC mode */
    msr cpsr_c, r1
    ldr sp, =_stack_top    /* restore SVC's own sp (clobbered above) */

    BLINK_N 2   /* checkpoint 2: mode-switching / stack setup done */

    /* QEMU's ELF loader does not clear .bss -- do it ourselves before
     * any vani code (which may rely on zero-initialized statics) runs. */
    ldr r0, =__bss_start
    ldr r1, =__bss_end
    mov r2, #0
clear_bss:
    cmp r0, r1
    bge clear_bss_done
    str r2, [r0]
    add r0, r0, #4
    b clear_bss
clear_bss_done:

    BLINK_N 3   /* checkpoint 3: .bss clear done */

    /* Round 38: page table lives in .bss (mmu_init.S), so it must be
     * built AFTER clear_bss above, not before -- otherwise the zero
     * fill would wipe out every descriptor mmu_init just wrote. */
    bl mmu_init

    BLINK_N 4   /* checkpoint 4: mmu_init returned */

    bl kernel_main

hang:
    BLINK_N 5   /* checkpoint 5, repeating: kernel_main returned --
                 * should never happen (it runs forever), a sentinel
                 * if it somehow does */
    b hang
