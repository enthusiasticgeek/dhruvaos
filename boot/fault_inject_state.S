/* Dhruva -- fault-injection countdowns for the shell `fault` command's
 * remaining fault types (round 51 already did allocation-failure, in
 * runtime_stubs.c since dhruva_alloc_bytes is a C function; these
 * three live in vani instead, since their injection points --
 * sdhost_write_block, irq_dispatch, netif_send_frame -- are all vani
 * functions). Same "0 means disarmed, production behavior completely
 * unaffected" contract as dhruva_fault_inject_alloc_arm.
 *
 * write:    forces the Nth subsequent sdhost_write_block call to fail
 *           (a real I/O error, without touching hardware) -- exercises
 *           DharaFS's own write-failure handling (dharafs_compact's
 *           "single failure leaves log_start where it was" logic,
 *           dharafs_append's status checking) on demand.
 * irqburst: on the next real timer tick, jumps tick_count forward by
 *           N EXTRA ticks (via scheduler_set_tick_count_test_only) --
 *           simulates the CLOCK's view of "N ticks' worth of time
 *           passed without intervening scheduling work happening in
 *           between" (a slow/blocked ISR catching up). Deliberately
 *           does NOT simulate N real, distinct context-switch/
 *           preemption events firing in rapid succession -- that would
 *           need looping inside scheduler_switch_from_irq's own AAPCS-
 *           sensitive native asm (context_switch.S), exactly the class
 *           of code round 53 already found a real, hard-to-spot
 *           callee-saved-register bug in. Not worth that risk for a
 *           test-only convenience; a time-warp is honestly scoped as
 *           exactly that, not oversold as a full preemption-burst
 *           simulator.
 * netdrop:  forces the next N netif_send_frame calls to silently
 *           discard the frame while still reporting success -- the
 *           single lowest-level choke point every outgoing frame
 *           (ARP/IPv4/ICMP/UDP/TCP) already passes through, so this
 *           covers all of them from one injection point. Looks
 *           identical to a real dropped packet to the sender (which
 *           never learns a "send" call was internally faked), letting
 *           existing timeout/retransmission logic (round 37) be
 *           exercised on demand in a live session instead of only via
 *           test/*.py's own synthetic packet-loss construction. */

.section ".bss"
.align 4
fault_write_countdown:
    .word 0
fault_irqburst_countdown:
    .word 0
fault_netdrop_countdown:
    .word 0

.section ".text"

.global fault_write_countdown_get
fault_write_countdown_get:
    ldr r0, =fault_write_countdown
    ldr r0, [r0]
    bx lr

.global fault_write_countdown_set
fault_write_countdown_set:
    ldr r1, =fault_write_countdown
    str r0, [r1]
    mov r0, #0
    bx lr

.global fault_irqburst_countdown_get
fault_irqburst_countdown_get:
    ldr r0, =fault_irqburst_countdown
    ldr r0, [r0]
    bx lr

.global fault_irqburst_countdown_set
fault_irqburst_countdown_set:
    ldr r1, =fault_irqburst_countdown
    str r0, [r1]
    mov r0, #0
    bx lr

.global fault_netdrop_countdown_get
fault_netdrop_countdown_get:
    ldr r0, =fault_netdrop_countdown
    ldr r0, [r0]
    bx lr

.global fault_netdrop_countdown_set
fault_netdrop_countdown_set:
    ldr r1, =fault_netdrop_countdown
    str r0, [r1]
    mov r0, #0
    bx lr
