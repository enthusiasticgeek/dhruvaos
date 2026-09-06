/* Dhruva round 43 -- AArch64 exception vector table (BCM2711 / Pi 4).
 *
 * Built BEFORE any real interrupt/timer/GIC work, same order round 38
 * established for the Pi 1 MMU work: fault diagnostics are a genuine
 * prerequisite for bringing up anything else on this target, not an
 * afterthought bolted on once something breaks. Every entry here is
 * diagnostic-only for v1 -- report what happened over UART, then halt
 * -- never a silent infinite loop, which is what a stub/empty vector
 * table would produce on the very first unexpected exception (and on
 * real ARMv8 hardware, an unpopulated VBAR_EL1 target is worse than
 * silence -- it's execution of whatever garbage happens to be at
 * address 0, or wherever VBAR_EL1 was left pointing by reset).
 *
 * AArch64's vector table has 16 entries in 4 groups of 4 (Synchronous/
 * IRQ/FIQ/SError), one group per "exception source" case: current EL
 * with SP_EL0, current EL with SP_ELx, lower EL via AArch64, lower EL
 * via AArch32. This v1 kernel runs entirely at EL1 using its own
 * SP_EL1 (see boot.S's el1_entry) and has no EL0 code yet, so only
 * the second group (current EL, SPx) is ever expected to actually
 * fire -- the other three are populated with the exact same handler
 * regardless, so an unexpected exception from a future round's EL0
 * code (or a boot.S bug that leaves SP0 selected by mistake) still
 * gets a real diagnostic instead of silent corruption.
 *
 * Each entry is exactly 0x80 (128) bytes, per the architecture --
 * nowhere near enough room for a full diagnostic inline, so every
 * entry just tags itself with a small integer and branches to the
 * shared aarch64_fault_common handler, which has all the room it
 * needs. The whole table must start on a 2KB (0x800) boundary --
 * VBAR_EL1's low 11 bits are RES0 -- enforced by link.ld's own
 * ALIGN(0x800) on this section, not just the .align directive here
 * (which only guarantees natural alignment within whatever address
 * the linker happens to place this section at).
 */

.section ".vectors", "ax"
.align 11
.global vector_table
vector_table:
/* Current EL, SP0 */
.align 7
    mov x0, #0
    b aarch64_fault_common
.align 7
    mov x0, #1
    b aarch64_fault_common
.align 7
    mov x0, #2
    b aarch64_fault_common
.align 7
    mov x0, #3
    b aarch64_fault_common
/* Current EL, SPx -- the group this kernel actually runs under */
.align 7
    mov x0, #4
    b aarch64_fault_common
.align 7
    /* Round 70: this is now a REAL interrupt vector, not a diagnostic
     * dead end -- see aarch64_irq_handler below. Every OTHER vector in
     * this table still deliberately goes to aarch64_fault_common
     * (halt + report), since nothing else is expected to fire yet. */
    b aarch64_irq_handler
.align 7
    mov x0, #6
    b aarch64_fault_common
.align 7
    mov x0, #7
    b aarch64_fault_common
/* Lower EL, AArch64 */
.align 7
    mov x0, #8
    b aarch64_fault_common
.align 7
    mov x0, #9
    b aarch64_fault_common
.align 7
    mov x0, #10
    b aarch64_fault_common
.align 7
    mov x0, #11
    b aarch64_fault_common
/* Lower EL, AArch32 */
.align 7
    mov x0, #12
    b aarch64_fault_common
.align 7
    mov x0, #13
    b aarch64_fault_common
.align 7
    mov x0, #14
    b aarch64_fault_common
.align 7
    mov x0, #15
    b aarch64_fault_common

.section ".text"
/* x0 = vector index (0-15, see the table's own layout comment above).
 * Reports the index, ESR_EL1 (exception class/syndrome), ELR_EL1
 * (faulting return address), and FAR_EL1 (faulting data address, only
 * meaningful for sync data/instruction aborts but harmless to print
 * regardless) over the PL011 UART, then halts -- never returns, same
 * "report then halt, don't silently spin" convention boot/rpi1/
 * vectors.S's fault_data_abort/fault_prefetch_abort already use.
 */
.global aarch64_fault_common
aarch64_fault_common:
    mov x19, x0
    mrs x20, esr_el1
    mrs x21, elr_el1
    mrs x22, far_el1

    adr x1, fault_msg_vector
    bl uart_puts_rpi4
    mov x0, x19
    bl uart_put_hex64_rpi4

    adr x1, fault_msg_esr
    bl uart_puts_rpi4
    mov x0, x20
    bl uart_put_hex64_rpi4

    adr x1, fault_msg_elr
    bl uart_puts_rpi4
    mov x0, x21
    bl uart_put_hex64_rpi4

    adr x1, fault_msg_far
    bl uart_puts_rpi4
    mov x0, x22
    bl uart_put_hex64_rpi4

    adr x1, newline_msg
    bl uart_puts_rpi4

fault_halt:
    wfe
    b fault_halt

.equ IRQ_GICC_BASE, 0xFF842000
.equ IRQ_GICC_IAR, 0x00C
.equ IRQ_GICC_EOIR, 0x010
.equ IRQ_TIMER_INTID, 30
.equ IRQ_SPURIOUS_INTID, 1023
/* Round 77: UART0 RX. NOT guessed -- fetched QEMU 10.0.0's own
 * hw/arm/bcm2838_peripherals.h directly, which defines
 * GIC_SPI_INTERRUPT_UART0 as 121 (an SPI *index*, not an INTID
 * directly -- GICv2's own convention: SPI index N maps to INTID
 * N+32, PPIs/SGIs occupying 0-31 first). 32 + 121 = 153. Confirmed
 * this is the same convention round 70's own PPI-to-INTID derivation
 * used for the timer (PPI 14 -> INTID 30 = 16+14) -- SPIs offset by
 * 32 instead of PPIs' 16, per the GICv2 spec's own INTID layout. */
.equ IRQ_UART0_INTID, 153
/* IRQ_HALT_AFTER_TICKS (was 5) moved into kernel_main_rpi4.vani's own
 * rpi4_handle_timer_irq (round 75) along with the rest of the tick-
 * counting/message/halt-vs-rearm decision this constant used to gate
 * inline here. */

/* Round 70: the real IRQ handler boot/rpi4/gic_timer.S's timer
 * targets. UNLIKE aarch64_fault_common (which halts and never
 * returns), this handler RESUMES the interrupted context via `eret`
 * -- so it saves and restores ALL 31 general-purpose registers
 * up front, not just the handful it happens to use itself. An
 * interrupt can land anywhere, including mid-sequence in code
 * holding a live value in a callee-saved register across many
 * instructions; only a full save makes it safe to freely use any
 * register (and to call other functions) inside this handler without
 * auditing every one of them against whatever the interrupted code
 * might have been doing. ELR_EL1/SPSR_EL1 themselves are left alone
 * (never written here), so `eret` naturally resumes at the correct
 * PC with the correct PSTATE -- unlike x0-x30, hardware already
 * banked those automatically on exception entry.
 *
 * Verification note: the first live run of this handler showed the
 * 4th and 5th printed "tick=" lines apparently arriving within ~1ms
 * of each other, wall-clock, after ticks 1-3 had each shown a clean
 * ~500ms gap -- looked exactly like a double-fire bug right before
 * halting. Investigated properly rather than dismissed OR trusted
 * blindly: a temporary debug build printed CNTPCT_EL0 (the raw
 * hardware counter) at every tick, and the counter DELTA between
 * every consecutive pair -- including 4th-to-5th -- was consistently
 * ~31.25M ticks apart, matching CNTFRQ_EL0/2 exactly. The apparent
 * "instant" 5th print was a QEMU stdio/pty output-buffering artifact
 * right before the final halt message flushed, not a real firmware
 * timing bug. Confirming against the actual hardware counter, not
 * just wall-clock print arrival time, is what actually settled this.
 *
 * ROUND 75 UPDATE: the tick-counting/message/halt-vs-rearm decision
 * that used to run inline here (right after the INTID dispatch below)
 * is now real vani-compiled code (kernel_main_rpi4.vani's own
 * rpi4_handle_timer_irq) -- the second concrete increment of porting
 * kernel_main.vani's boot-facing pieces to this target (round 74 did
 * the first, a one-shot boot-time proof; this is the first vani code
 * on this port to run from a genuinely repeated, interrupt-driven call
 * site). The full x0-x30 save/restore this handler already needed
 * regardless (see above) is exactly what makes that call site safe
 * with zero extra register-preservation work -- see that function's
 * own comment in kernel_main_rpi4.vani for the full reasoning.
 */
.global aarch64_irq_handler
aarch64_irq_handler:
    /* Round 79: grew from 256 to 272 bytes to also hold ELR_EL1/
     * SPSR_EL1 -- see boot/rpi4/preempt_switch.S's own header comment
     * for why a handler that might resume a DIFFERENT context than
     * the one it interrupted needs these explicitly saved per-frame,
     * not left as ambient hardware state. */
    sub sp, sp, #272
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x19, [sp, #144]
    stp x20, x21, [sp, #160]
    stp x22, x23, [sp, #176]
    stp x24, x25, [sp, #192]
    stp x26, x27, [sp, #208]
    stp x28, x29, [sp, #224]
    str x30, [sp, #240]
    mrs x0, elr_el1
    mrs x1, spsr_el1
    stp x0, x1, [sp, #248]

    ldr x0, =IRQ_GICC_BASE
    ldr w1, [x0, #IRQ_GICC_IAR]
    and w19, w1, #0x3FF          /* INTID is bits[9:0] of GICC_IAR */

    cmp w19, #IRQ_SPURIOUS_INTID
    b.eq irq_restore              /* spurious: no EOI, nothing to do */

    cmp w19, #IRQ_TIMER_INTID
    b.eq irq_timer

    /* Round 77: UART0 RX (see IRQ_UART0_INTID's own comment below for
     * how this INTID was derived). Same dispatch shape as the timer
     * branch -- anything that isn't one of our two known sources just
     * falls through to a plain EOI. */
    cmp w19, #IRQ_UART0_INTID
    b.eq irq_uart0

    b irq_eoi                     /* unknown source: EOI it and move on */

irq_timer:
    /* Round 75: the tick-counting/message/halt-vs-rearm decision that
     * used to live here inline is now real vani-compiled code
     * (kernel_main_rpi4.vani's own rpi4_handle_timer_irq) -- safe to
     * call with zero extra register-preservation work on this side,
     * since every one of x0-x30 is already unconditionally saved above
     * (this handler must do that regardless, to resume the interrupted
     * context via `eret` below) -- see that function's own comment for
     * the full reasoning.
     *
     * Round 79: that call now returns a real signal (x0 = force_boot:
     * 1 on the halting tick, 0 otherwise), fed straight into
     * rpi4_preempt_switch (boot/rpi4/preempt_switch.S) along with the
     * CURRENT frame pointer -- it saves the current frame into
     * whichever task the scheduler thinks is running, decides who's
     * next, and returns THAT task's saved sp, which may genuinely
     * differ from the one we entered with. `mov sp, x0` here is the
     * entire "switch" from this handler's own perspective -- the
     * shared irq_restore epilogue below does the rest, uniformly,
     * whether or not an actual switch happened. */
    bl rpi4_handle_timer_irq
    mov x1, x0
    mov x0, sp
    bl rpi4_preempt_switch
    mov sp, x0
    b irq_eoi

irq_uart0:
    /* Round 77: RX-FIFO drain + echo, real vani code from the start
     * (kernel_main_rpi4.vani's own rpi4_handle_uart_rx_irq) -- same
     * zero-extra-register-preservation safety as the timer call site
     * above, for the same reason. */
    bl rpi4_handle_uart_rx_irq

irq_eoi:
    ldr x0, =IRQ_GICC_BASE
    str w19, [x0, #IRQ_GICC_EOIR]

/* Round 81: exported so boot/rpi4/preempt_switch.S's own
 * preempt_generic_switch can share this exact restore+eret sequence
 * for a VOLUNTARY switch too, instead of duplicating it -- a
 * voluntary yield builds the identical 272-byte frame shape an
 * interrupt does (see that function's own comment for why this
 * works: `eret` only needs valid ELR_EL1/SPSR_EL1 at the moment it
 * executes, regardless of whether the CPU arrived via a real
 * hardware exception or via ordinary code that set them manually). */
.global irq_restore
irq_restore:
    /* Round 79: restore ELR_EL1/SPSR_EL1 from THIS frame (whichever
     * one sp now points at -- possibly a different task's, if the
     * timer branch just switched) before touching x0/x1 for real.
     * Unconditional, even for spurious/UART0 (which never switch):
     * putting back the exact same value they already hold is a
     * no-op, and a shared, uniform epilogue is far less error-prone
     * than special-casing "did a switch happen" here. */
    ldp x0, x1, [sp, #248]
    msr elr_el1, x0
    msr spsr_el1, x1

    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldp x16, x17, [sp, #128]
    ldp x18, x19, [sp, #144]
    ldp x20, x21, [sp, #160]
    ldp x22, x23, [sp, #176]
    ldp x24, x25, [sp, #192]
    ldp x26, x27, [sp, #208]
    ldp x28, x29, [sp, #224]
    ldr x30, [sp, #240]
    add sp, sp, #272
    eret

/* i64 rpi4_timer_tick_count_increment(void) -- round 75, the one
 * piece of this file's own timer-tick logic that stayed in hand-
 * written assembly once the rest (message printing, the halt-vs-
 * rearm decision) moved into real vani code (kernel_main_rpi4.vani's
 * own rpi4_handle_timer_irq) -- vani has no top-level global-variable
 * mechanism, so irq_tick_count still needs a .bss-plus-extern-accessor
 * home here, the exact same shape every persistent-state file on the
 * Pi 1 side already uses (e.g. boot/context_switch.S's irq_count).
 * Increments THEN returns the new value, matching the old inline
 * assembly's own `add w2,w2,#1` before using w2 -- so a first real
 * tick reads back as 1, not 0. */
.global rpi4_timer_tick_count_increment
rpi4_timer_tick_count_increment:
    adrp x0, irq_tick_count
    add x0, x0, :lo12:irq_tick_count
    ldr w1, [x0]
    add w1, w1, #1
    str w1, [x0]
    mov x0, x1
    ret

/* i64 rpi4_timer_tick_count_get(void) -- round 82: a plain,
 * non-incrementing read of the same counter, for
 * boot/rpi4/preempt_switch.S's own voluntary-sleep primitive (needs
 * "what tick is it right now" to compute a wake tick and to check
 * whether a sleeping task's wake tick has arrived yet -- neither of
 * those should ALSO advance the real tick count, which only
 * rpi4_handle_timer_irq's own call above is allowed to do). */
.global rpi4_timer_tick_count_get
rpi4_timer_tick_count_get:
    adrp x0, irq_tick_count
    add x0, x0, :lo12:irq_tick_count
    ldr w1, [x0]
    mov x0, x1
    ret

/* x0 = value to print as 16 hex digits, most-significant nibble
 * first -- the AArch64 twin of boot/rpi1's own uart_put_hex32, sized
 * for a 64-bit register instead of a 32-bit one.
 *
 * BUG (round 70 audit): x23/x24/x25 are AAPCS64 CALLEE-SAVED registers
 * (x19-x28), used here as scratch with no save/restore. Harmless as
 * long as every caller immediately halted afterward (aarch64_fault_
 * common's own diagnostic path, kmain_rpi4's one-shot boot print) --
 * but round 70's real, RESUMING IRQ handler (aarch64_irq_handler,
 * below) needs to call this from the middle of live execution it
 * must return to correctly, where a caller's own live x23-x25 values
 * would otherwise be silently corrupted. Found and fixed before ever
 * wiring that call in, not discovered live -- the same AAPCS
 * callee-saved-register-clobber bug CLASS this project has already
 * hit more than once on the ARM32 side (a hand-written asm function
 * using a callee-saved register as unsaved scratch), just on the
 * AArch64 side and a different specific register set this time. */
.global uart_put_hex64_rpi4
uart_put_hex64_rpi4:
    sub sp, sp, #48
    stp x29, x30, [sp, #0]
    stp x23, x24, [sp, #16]
    str x25, [sp, #32]
    mov x23, x0
    mov x24, #60
    ldr x25, =0xFE201000
1:
    lsr x0, x23, x24
    and x0, x0, #0xF
    cmp x0, #10
    b.lt 2f
    add x0, x0, #('A' - 10)
    b 3f
2:
    add x0, x0, #'0'
3:
poll_tx:
    ldr w1, [x25, #0x18]
    tbnz w1, #5, poll_tx
    strb w0, [x25]
    subs x24, x24, #4
    b.ge 1b
    ldr x25, [sp, #32]
    ldp x23, x24, [sp, #16]
    ldp x29, x30, [sp, #0]
    add sp, sp, #48
    ret

.section ".rodata"
fault_msg_vector:
    .asciz "\nDHRUVA RPI4 FAULT: vector="
fault_msg_esr:
    .asciz " ESR_EL1="
fault_msg_elr:
    .asciz " ELR_EL1="
fault_msg_far:
    .asciz " FAR_EL1="
.align 4

.section ".bss"
.align 4
irq_tick_count:
    .word 0
.align 4
