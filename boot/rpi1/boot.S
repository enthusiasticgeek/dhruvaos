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
/* Round 2026-09-15 real-hardware timing investigation: the user reported
 * a real, reproducible 5-10 minute pause between the GPU's own "Starting
 * ARM" handoff and DharaFS/self-tests appearing on UART, with the SAME
 * LED checkpoint blink count repeating the whole time (i.e. not a reset
 * loop -- one checkpoint genuinely taking that long). A TIMER_CLO read
 * added at kernel_main's own first line already proved the pause is
 * entirely BEFORE kernel_main ever runs (TIMER_CLO read ~359s there vs.
 * the GPU's own ~2.7s "Starting ARM" timestamp, while everything AFTER
 * kernel_main -- SD init, DharaFS, the full self-test suite -- completes
 * in well under a minute), which points squarely at boot_entry's own
 * pre-kernel_main code below. This snapshots TIMER_CLO (BCM2835 System
 * Timer low 32 bits, free-running at 1MHz, independent of ARM core
 * state) at each of the existing 7 LED checkpoints PLUS boot_entry's own
 * very first instruction (checkpoint 0), so kernel_main can print all 8
 * once UART is up and pinpoint exactly which checkpoint transition eats
 * the time -- narrowing from "somewhere in ~250 lines of boot.S" to one
 * specific segment, the same evidence-first approach that found the
 * cache/MMU/vector-table bugs on 2026-09-12/13.
 *
 * Storage MUST be .data, not .bss: checkpoint 5 below zeroes .bss, which
 * would wipe any checkpoint values already stored there before that
 * point. Uses r2/r3 only -- verified free (not live) at every insertion
 * point: checkpoint 0 is the function's first instruction; checkpoints
 * 1/5/6 only have r0/r1 live at that point (cache-op garbage / bss-clear
 * loop vars, both dead by the time each BLINK_N fires); checkpoints
 * 2/3/4 keep the saved CPSR in r0 and a scratch mode value in r1 across
 * the whole mode-switching block (see their own comments below) --
 * neither is r2 or r3, so this can't clobber them. */
.macro SNAP_TIMER slot
    ldr r2, =0x20003004         /* TIMER_CLO */
    ldr r3, [r2]
    ldr r2, =boot_checkpoint_\slot
    str r3, [r2]
.endm

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
.global boot_entry

boot_entry:
    SNAP_TIMER 0    /* checkpoint 0: boot_entry's own first instruction --
                     * a small value here (close to the GPU's own
                     * "Starting ARM" timestamp) rules out the GPU/ARM
                     * handoff itself as the source of the delay. */

    /* FOUND 2026-09-13, comparing against Linux's own arch/arm/kernel/
     * head.S (ENTRY(stext)) after the vector-table fix above still did
     * not produce a working real-hardware boot -- the user's own
     * suggestion to check other proven GitHub Pi 1 sources, not just
     * dwelch67's minimal examples, is what surfaced this. Linux's own
     * ARM entry point does NOT trust the CPU is in SVC mode with
     * interrupts masked when the kernel starts -- its very first real
     * action (after an optional Hyp-mode check, irrelevant here: this
     * ARM1176 core predates Hyp mode entirely) is `safe_svcmode_
     * maskall`: force SVC mode, mask IRQ AND FIQ, unconditionally,
     * before anything else runs. The comment on that macro in
     * arch/arm/include/asm/assembler.h is explicit that this exists
     * because various real bootloaders/firmware do NOT reliably hand
     * off in that state -- this is not theoretical caution, it is a
     * real, extensively-hit class of bug across the whole ARM Linux
     * ecosystem, encoded directly into the kernel's own entry point
     * for exactly that reason.
     *
     * This project's own boot_entry has NEVER done this -- it assumes
     * SVC mode + masked interrupts as a given (true of the ARM
     * architectural reset state, and true of QEMU's own `-kernel`
     * boot by construction, but NOT verified against whatever real
     * GPU firmware's own handoff actually does). If firmware hands off
     * via anything other than a genuine CPU reset -- a plain branch
     * from firmware's own still-running context, which may have
     * interrupts enabled for its own purposes -- an IRQ or FIQ could
     * fire at literally the first instruction of this function, before
     * the vector table below is even copied, jumping to whatever
     * garbage already occupies address 0x00000000/0x18/0x1C at that
     * exact moment. This exact class of bug is invisible under QEMU
     * by construction (its own `-kernel` loader always starts from a
     * clean, fully-masked SVC-mode state), matching every other real-
     * hardware-only bug found this investigation.
     *
     * Fixed the same way Linux's own macro does for a pre-Hyp-mode
     * core (its own "#else" branch, since ARM1176 has no Hyp mode to
     * check for): read CPSR, force mode=SVC and set both I and F mask
     * bits, unconditionally, as literally the first instructions this
     * function executes -- before even the vector-table copy, since
     * that copy itself must not be interruptible either. */
    mrs r0, cpsr
    bic r0, r0, #0x1F      /* clear mode bits */
    orr r0, r0, #0xD3      /* SVC mode (0x13) | I mask (0x80) | F mask (0x40) */
    msr cpsr_c, r0

    /* TASK #163 FIX (2026-09-12): copy the vector table (vectors.S's
     * own `_start`/`_vectors`, now linked immediately before this
     * function at the REAL entry point, 0x8000 -- see link.ld's own
     * `.vectors` comment for the full reasoning) down to address
     * 0x00000000, where the ARM core's own hardware actually reads
     * exception vectors from (ARMv6 has no VBAR). This function used
     * to BE `_start` itself, before this fix moved the vector table
     * to the real entry point and renamed this to `boot_entry` --
     * confirmed against dwelch67/raspberrypi's own well-known,
     * PROVEN blinker05 example, which does exactly this same 16-word
     * (64-byte) copy for exactly this same reason. Must happen before
     * ANYTHING that could plausibly take an exception -- first thing
     * in this function, before even the LED diagnostic's own GPIO
     * setup below. */
    ldr r0, =_start
    mov r1, #0
    ldmia r0!, {r2, r3, r4, r5, r6, r7, r8, r9}
    stmia r1!, {r2, r3, r4, r5, r6, r7, r8, r9}
    ldmia r0!, {r2, r3, r4, r5, r6, r7, r8, r9}
    stmia r1!, {r2, r3, r4, r5, r6, r7, r8, r9}

    /* One-time GPIO16 output setup for the diagnostic below. */
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

    SNAP_TIMER 1
    BLINK_N 1   /* checkpoint 1: cache/MMU/TLB invalidation done */

    ldr sp, =_stack_top

    mrs r0, cpsr
    bic r1, r0, #0x1F
    orr r1, r1, #0x12      /* IRQ mode */
    msr cpsr_c, r1
    ldr sp, =_irq_stack_top

    SNAP_TIMER 2
    BLINK_N 2   /* checkpoint 2 (round 2026-09-13, real-hardware
                 * investigation): IRQ mode entered, sp_irq set. Split
                 * out from the old single "mode-switching / stack
                 * setup done" checkpoint after the user reported a
                 * live LED pattern (one short blink, then stuck ON
                 * for ~2s) matching checkpoint 1 completing but
                 * something failing before the old checkpoint 2 ever
                 * fired -- narrowing down WHICH of the three mode
                 * switches below is actually the problem, rather than
                 * guessing, on the next real-hardware attempt. */

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

    SNAP_TIMER 3
    BLINK_N 3   /* checkpoint 3 (round 2026-09-13): Abort mode entered,
                 * sp_abt set. See checkpoint 2's own comment above. */

    bic r1, r0, #0x1F
    orr r1, r1, #0x13      /* back to SVC mode */
    msr cpsr_c, r1
    ldr sp, =_stack_top    /* restore SVC's own sp (clobbered above) */

    SNAP_TIMER 4
    BLINK_N 4   /* checkpoint 4 (was checkpoint 2 before the 2026-09-13
                 * split above): back in SVC mode, sp restored --
                 * mode-switching / stack setup fully done */

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

    SNAP_TIMER 5
    BLINK_N 5   /* checkpoint 5 (was 3): .bss clear done */

    /* Round 38: page table lives in .bss (mmu_init.S), so it must be
     * built AFTER clear_bss above, not before -- otherwise the zero
     * fill would wipe out every descriptor mmu_init just wrote. */
    bl mmu_init

    SNAP_TIMER 6
    BLINK_N 6   /* checkpoint 6 (was 4): mmu_init returned */

    bl kernel_main

hang:
    BLINK_N 7   /* checkpoint 7 (was 5), repeating: kernel_main returned --
                 * should never happen (it runs forever), a sentinel
                 * if it somehow does */
    b hang

/* Storage for the SNAP_TIMER checkpoints above. Deliberately .data, not
 * .bss -- see SNAP_TIMER's own comment: checkpoint 5 zeroes .bss, which
 * would wipe these if they lived there. link.ld places .data right
 * before __bss_start, so this is unaffected by that clear regardless of
 * which checkpoint fires first. */
.section ".data"
.align 4
.global boot_checkpoint_0
.global boot_checkpoint_1
.global boot_checkpoint_2
.global boot_checkpoint_3
.global boot_checkpoint_4
.global boot_checkpoint_5
.global boot_checkpoint_6
boot_checkpoint_0: .word 0
boot_checkpoint_1: .word 0
boot_checkpoint_2: .word 0
boot_checkpoint_3: .word 0
boot_checkpoint_4: .word 0
boot_checkpoint_5: .word 0
boot_checkpoint_6: .word 0

/* Getters for kernel_main.vani, matching usb_wifi_state.S's own
 * established extern-fn pattern exactly: return value in r0, r1=0 (no
 * error code needed here, but kept for calling-convention consistency
 * with every other extern fn this project calls from vani). */
.section ".text.boot_diag"
.global boot_diag_get_checkpoint_0
.global boot_diag_get_checkpoint_1
.global boot_diag_get_checkpoint_2
.global boot_diag_get_checkpoint_3
.global boot_diag_get_checkpoint_4
.global boot_diag_get_checkpoint_5
.global boot_diag_get_checkpoint_6

boot_diag_get_checkpoint_0:
    ldr r0, =boot_checkpoint_0
    ldr r0, [r0]
    mov r1, #0
    bx lr

boot_diag_get_checkpoint_1:
    ldr r0, =boot_checkpoint_1
    ldr r0, [r0]
    mov r1, #0
    bx lr

boot_diag_get_checkpoint_2:
    ldr r0, =boot_checkpoint_2
    ldr r0, [r0]
    mov r1, #0
    bx lr

boot_diag_get_checkpoint_3:
    ldr r0, =boot_checkpoint_3
    ldr r0, [r0]
    mov r1, #0
    bx lr

boot_diag_get_checkpoint_4:
    ldr r0, =boot_checkpoint_4
    ldr r0, [r0]
    mov r1, #0
    bx lr

boot_diag_get_checkpoint_5:
    ldr r0, =boot_checkpoint_5
    ldr r0, [r0]
    mov r1, #0
    bx lr

boot_diag_get_checkpoint_6:
    ldr r0, =boot_checkpoint_6
    ldr r0, [r0]
    mov r1, #0
    bx lr
