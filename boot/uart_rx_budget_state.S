/* Dhruva -- UART RX interrupt-triggered work, bounded against a real
 * budget (RTOS true-compliance pass, task #242).
 *
 * docs/RTOS_GAP_ANALYSIS.md's own "no aperiodic/sporadic server" item:
 * UART RX interrupt-triggered work (irq_dispatch's own PL011 RX
 * branch, kernel_main.vani) runs directly inside the ISR, with no
 * accounting against any task's own time allowance. Each single IRQ
 * entry is already WCET-bounded (the 128-byte drain loop irq_dispatch's
 * own #[wcet(cycles=130000)] budget was raised for) -- but nothing
 * bounds how many separate RX IRQ entries can happen back-to-back
 * within one timer-tick period. Since the PL011's own RX interrupt is
 * LEVEL-triggered (stays asserted as long as the FIFO is above its
 * trigger threshold), a sustained stream of RX bytes arriving faster
 * than useful periodic work can proceed has no software rate limit at
 * all today -- the real gap this closes.
 *
 * uart_rx_irq_budget: remaining RX-IRQ services allowed this tick
 * period, replenished to UART_RX_IRQ_BUDGET_PER_TICK (kernel_main.vani)
 * at the top of irq_dispatch's own timer-tick branch. Decremented once
 * per RX IRQ entry that actually drains the FIFO.
 *
 * uart_rx_deferred: 0/1. Set when an RX IRQ entry finds the budget
 * already exhausted -- instead of draining (which would just keep
 * consuming CPU with no accounting), that entry masks the PL011's own
 * RXIM bit (UART_IMSC), so the level-triggered condition cannot
 * re-assert and force another IRQ entry immediately (a real livelock
 * risk this design deliberately avoids -- "defer without masking"
 * would busy-loop instead of yielding). Checked (and cleared, with
 * RXIM re-enabled) at the top of the next timer-tick branch, once a
 * fresh budget is available.
 *
 * Real, accepted, documented tradeoff (not a bug): bytes that arrive
 * while RX is masked queue only as deep as the PL011's real 16-byte
 * hardware FIFO, then get silently dropped by the hardware itself
 * (real UART FIFO-overflow behavior) until the next tick unmasks RX
 * again. This bounds the periodic task set's own worst-case interrupt
 * exposure at the cost of guaranteed-lossless interactive echo during
 * a genuine sustained burst -- the standard sporadic-server tradeoff,
 * not unique to this implementation. UART_RX_IRQ_BUDGET_PER_TICK is
 * deliberately generous (512 bytes/tick at the default value) so this
 * never triggers under real interactive typing speed, only a genuine
 * machine-speed flood. */

.section ".bss"
.align 4
uart_rx_irq_budget:
    .word 0
uart_rx_deferred:
    .word 0

.section ".text"

.global uart_rx_irq_budget_get
uart_rx_irq_budget_get:
    ldr r0, =uart_rx_irq_budget
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global uart_rx_irq_budget_set
uart_rx_irq_budget_set:
    ldr r1, =uart_rx_irq_budget
    str r0, [r1]
    mov r1, #0
    bx lr

.global uart_rx_deferred_get
uart_rx_deferred_get:
    ldr r0, =uart_rx_deferred
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global uart_rx_deferred_set
uart_rx_deferred_set:
    ldr r1, =uart_rx_deferred
    str r0, [r1]
    mov r1, #0
    bx lr
