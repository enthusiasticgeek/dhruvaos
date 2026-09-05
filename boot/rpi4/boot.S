/* Dhruva round 43 -- Raspberry Pi 4 (BCM2711) AArch64 boot skeleton.
 *
 * First real, committed code for the Pi 4/5 port opened as research
 * in round 40 (see docs/PORTING.md's "Correction (round 40)" section
 * and docs/TODO.md's Pi 4/5 port entry for the full context). Round
 * 40 validated -- via a throwaway /tmp spike, never checked in --
 * that qemu-system-aarch64 -M raspi4b boots a raw ELF via -kernel the
 * same way this project's Pi 1 target already relies on, that QEMU
 * starts execution at EL3 (not EL1 the way ARM1176 always was), and
 * that the PL011 UART lives at 0xFE201000. This file is that spike's
 * real, permanent replacement: a genuine EL3->EL1 privilege drop
 * (nothing like ARM1176's flat mode-switch model in boot/rpi1/boot.S)
 * plus the same "park secondary cores" convention every multi-core
 * ARM bring-up needs.
 *
 * v1 scope, deliberately: prove the boot+EL-drop+UART chain live and
 * correct, nothing more. No MMU, no vani-compiled kernel code yet (a
 * real vani kernel_main.vani port to AArch64 needs its own dedicated
 * round -- this round is the prerequisite that makes that possible at
 * all). Every claim below about *why* a register write matters is
 * verified live in round 43's own build+boot test
 * (test/rpi4_boot_smoke.py), not merely asserted from documentation --
 * matching this project's own established discipline (see round 38's
 * MMU work and round 40's own spike for the precedent).
 *
 * ROUND 70 UPDATE: GIC + generic-timer bring-up (boot/rpi4/
 * gic_timer.S) added below, after kmain_rpi4's own one-shot boot
 * print -- the first real interrupt-driven code on this port. MMU and
 * the vani kernel port remain not-yet-started; see docs/TODO.md's own
 * "Remaining scope for a real Pi 4 boot" list.
 */

.section ".text.boot"
.global _start
_start:
    /* Same "only core 0 proceeds, everyone else parks in a low-power
     * wait loop" convention every multi-core ARM bring-up needs --
     * BCM2711 (Cortex-A72, quad-core) always starts all 4 cores
     * simultaneously at the kernel entry point, same as BCM2837 (Pi
     * 3) already required and BCM2835 (Pi 1, single-core) never had
     * to worry about. mpidr_el1 bits [1:0] are the core's Aff0 field
     * on this SoC. */
    mrs x0, mpidr_el1
    and x0, x0, #3
    cbz x0, master
hang:
    wfe
    b hang

master:
    /* EL3 -> EL1 privilege drop. QEMU's raw -kernel boot (confirmed
     * live in round 40's spike via a CurrentEL read) skips the ARM
     * Trusted Firmware a real Pi 4's boot ROM/GPU firmware would
     * normally run, and drops straight into EL3 (Secure Monitor) --
     * real hardware would need this exact same drop regardless, TF-A
     * just happens to already do it before handing control to an OS
     * on real hardware. Standard three-register sequence, going
     * directly EL3 -> EL1 (skipping EL2 entirely, since this kernel
     * has no hypervisor role):
     *
     *   HCR_EL2.RW (bit 31): if execution ever DID pass through EL2,
     *     this says EL1 runs AArch64, not AArch32. Harmless to set
     *     even though this boot path never actually executes at EL2.
     *   SCR_EL3: NS=1 (bit 0, run the OS in the Non-secure world --
     *     the normal, expected world for anything that isn't a
     *     Trusted-Execution-Environment payload), RES1 bits 4-5 (the
     *     architecture requires these fixed at 1 on this revision),
     *     HCE=1 (bit 8, enable the HVC instruction -- harmless, not
     *     used by this v1 boot), RW=1 (bit 10, EL2 -- and, since EL2
     *     is being skipped here, effectively EL1 -- runs AArch64).
     *   SPSR_EL3: the processor state `eret` restores. M[3:0]=0b0101
     *     selects EL1h (EL1 using its own SP_EL1, not a borrowed
     *     SP_EL0) -- the normal target for a kernel that manages its
     *     own stack. DAIF=1111 (bits 6-9) masks all four interrupt
     *     classes (Debug/SError/IRQ/FIQ) until EL1 code explicitly
     *     unmasks them -- this v1 boot never does, since there's no
     *     GIC/timer/interrupt handling yet (a later round's job).
     *   ELR_EL3: the address `eret` jumps to -- el1_entry, below.
     */
    ldr x0, =(1 << 31)
    msr hcr_el2, x0

    ldr x0, =0x531          /* NS | RES1(4,5) | HCE | RW */
    msr scr_el3, x0

    ldr x0, =0x3c5          /* DAIF=1111, M[3:0]=0b0101 (EL1h) */
    msr spsr_el3, x0

    adr x0, el1_entry
    msr elr_el3, x0

    eret

el1_entry:
    /* Now running at EL1. Real AArch64 exception vectors (vectors.S)
     * before anything that could plausibly fault -- same "fault
     * diagnostics are a genuine prerequisite, build them first" order
     * round 38 established for the Pi 1 MMU work, not an afterthought
     * bolted on once something actually breaks. */
    adr x0, vector_table
    msr vbar_el1, x0

    ldr x0, =_stack_top
    mov sp, x0

    bl kmain_rpi4

    /* Round 70: GIC + generic-timer bring-up (boot/rpi4/gic_timer.S) --
     * the first real interrupt-driven code on this port. Enable the
     * distributor/CPU-interface/timer-PPI and arm the first tick
     * BEFORE unmasking IRQ at the PSTATE level, so there's no window
     * where an already-pending, not-yet-unmasked interrupt could fire
     * against half-initialized GIC state. */
    bl gic_timer_init
    msr daifclr, #2         /* unmask IRQ only; FIQ/SError/Debug stay masked */
    isb

heartbeat_loop:
    wfi
    b heartbeat_loop

/* Round 43 v1 "kernel": prove the boot+EL-drop+vector-install chain
 * is genuinely correct by printing a real message and the actual
 * CurrentEL value over the PL011 UART -- CurrentEL is read AT EL1
 * here, so a correct drop prints "1", not "3". A future round
 * replaces this with real vani-compiled kernel code once that half of
 * the port exists; this is deliberately the smallest possible proof
 * of the infrastructure this round is actually about.
 */
.global kmain_rpi4
kmain_rpi4:
    stp x29, x30, [sp, #-16]!

    adr x1, boot_msg
    bl uart_puts_rpi4

    mrs x2, CurrentEL
    lsr x2, x2, #2
    add x2, x2, #'0'
    adr x0, current_el_scratch
    strb w2, [x0]
    bl uart_puts_rpi4_el

    ldp x29, x30, [sp], #16
    ret

/* w0 = PL011 base address (0xFE201000, BCM2711 low-peripheral mode --
 * live-verified in round 40's spike, not assumed from a datasheet
 * alone), x1 = NUL-terminated string pointer. Polls UARTFR (offset
 * 0x18) bit 5 (TXFF, transmit FIFO full) before each byte -- the same
 * "no interrupts/DMA yet, just poll" style boot.S/vectors.S already
 * use for early diagnostics on the Pi 1 side. */
.global uart_puts_rpi4
uart_puts_rpi4:
    ldr x0, =0xFE201000
1:
    ldrb w3, [x1], #1
    cbz w3, 2f
3:
    ldr w4, [x0, #0x18]
    tbnz w4, #5, 3b
    strb w3, [x0]
    b 1b
2:
    ret

/* Same as uart_puts_rpi4 but prints current_el_scratch (a single
 * digit) then a newline -- split out only because kmain_rpi4 needs to
 * write the digit into that buffer first; no other difference.
 *
 * Real bug, found live while verifying the vector table (a deliberate
 * `udf` fault silently never reached the handler until this was
 * fixed): this function makes TWO nested `bl uart_puts_rpi4` calls but
 * never saved its OWN return address first -- the first `bl` sets x30
 * to point back here correctly, but the SECOND `bl` overwrites x30
 * again before this function's own final `ret` ever gets to use it,
 * so `ret` jumped to whatever address happened to follow the second
 * call, not back to kmain_rpi4. A leaf function that makes more than
 * one call of its own is not a leaf function -- it must save/restore
 * its own x30 (and x29, by convention) around any call it makes,
 * exactly like kmain_rpi4 (its only caller) already correctly does. */
.global uart_puts_rpi4_el
uart_puts_rpi4_el:
    stp x29, x30, [sp, #-16]!
    adr x1, current_el_scratch
    bl uart_puts_rpi4
    adr x1, newline_msg
    bl uart_puts_rpi4
    ldp x29, x30, [sp], #16
    ret

.section ".rodata"
boot_msg:
    .asciz "DHRUVA RPI4: EL3->EL1 drop OK, VBAR_EL1 installed, CurrentEL="
.global newline_msg
newline_msg:
    .asciz "\n"
.align 4

.section ".bss"
.align 4
current_el_scratch:
    .byte 0, 0
.align 4
