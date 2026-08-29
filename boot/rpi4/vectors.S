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
    mov x0, #5
    b aarch64_fault_common
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

/* x0 = value to print as 16 hex digits, most-significant nibble
 * first -- the AArch64 twin of boot/rpi1's own uart_put_hex32, sized
 * for a 64-bit register instead of a 32-bit one. */
.global uart_put_hex64_rpi4
uart_put_hex64_rpi4:
    stp x29, x30, [sp, #-16]!
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
    ldp x29, x30, [sp], #16
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
