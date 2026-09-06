/* Dhruva round 70 -- BCM2711 GICv2 + ARM generic timer, the first
 * real interrupt-driven code on the Pi 4/5 (AArch64) port. Prereq for
 * everything downstream in docs/TODO.md's Pi 4/5 port entry (a real
 * scheduler needs a real periodic tick, same role BCM2835's System
 * Timer + the simple BCM interrupt controller play on the Pi 1 side).
 *
 * GICD_BASE/GICC_BASE below are NOT guessed from a datasheet -- they
 * were derived by reading QEMU 10.0.0's own hw/arm/bcm2838.c (the
 * device model raspi4b's "-M raspi4b" machine actually instantiates):
 * bc_base->ctrl_base (0xff800000) + BCM2838_GIC_BASE (0x40000) +
 * GIC_DIST_OFS (0x1000) / GIC_CPU_OFS (0x2000) = 0xFF841000/0xFF842000.
 * These happen to also match real BCM2711 hardware's own documented
 * GIC-400 addresses (Linux's bcm2711.dtsi:
 * interrupt-controller@ff841000/ff842000) -- consistent with round
 * 40's own finding that this QEMU machine mirrors real hardware's
 * peripheral map rather than using placeholder addresses the way
 * QEMU's generic "virt" board does. Same "verify against the actual
 * source, don't just assume" discipline this project's crypto work
 * and round 40's own PL011-address spike both already established.
 *
 * Also confirmed by reading bcm2838.c: it never sets the GIC's
 * "has-security-extensions" property (default false), so this GIC
 * runs in a single security state -- GICD_CTLR/GICC_CTLR bit 0 is a
 * plain enable, no secure/non-secure register-view split to account
 * for. Simpler than a real TrustZone-aware GIC setup would need.
 *
 * The timer itself is NOT a BCM-specific memory-mapped peripheral the
 * way Pi 1's System Timer is -- it's the standard ARMv8-A architected
 * generic timer, driven purely through the CNTP-prefixed and
 * CNTFRQ_EL0 system registers, identical on every real ARMv8 core
 * regardless of SoC.
 * bcm2838.c wires the CPU's GTIMER_PHYS output (Non-secure EL1
 * physical timer) to GIC PPI 14 -- architected PPI number 14 means
 * INTID 30 (PPI/SGI INTIDs = 16 + PPI number, per the GICv2 spec),
 * not a hardcoded guess; boot/rpi4/vectors.S's aarch64_irq_handler
 * checks for exactly this INTID.
 *
 * CNTFRQ_EL0 is read live at init time, never hardcoded -- QEMU's own
 * target/arm/cpu.c defaults it to 1GHz for a non-backcompat CPU model
 * (confirmed by reading GTIMER_DEFAULT_HZ's own definition), but real
 * Pi 4 hardware's firmware-programmed value could differ, and this
 * driver has no business assuming either one.
 */

.equ GICD_BASE, 0xFF841000
.equ GICC_BASE, 0xFF842000
.equ GICD_CTLR, 0x000
.equ GICD_ISENABLER0, 0x100
.equ GICC_CTLR, 0x000
.equ GICC_PMR, 0x004

.section ".text"

/* Enables the GIC distributor + this CPU's interface, enables INTID
 * 30 (the timer PPI) specifically, sets the priority mask to accept
 * every priority (0xFF -- this kernel's interrupt sources are all
 * fielded at the same priority, priority filtering has nothing to do
 * yet), then arms the timer for a CNTFRQ_EL0/2-tick period (~500ms,
 * matching this project's own Pi 1 tick cadence in kernel_main.vani)
 * and enables it. Deliberately does NOT unmask IRQ at the PSTATE
 * level itself -- that's boot.S's own call, once it's actually ready
 * to field one.
 *
 * Round 77: UART0 RX (INTID 153) is enabled from vani code instead
 * (kernel_main_rpi4.vani's own rpi4_uart_rx_irq_init), not here --
 * unlike the timer's PPI, an SPI also needs GICD_ITARGETSR set (which
 * CPU(s) it's routed to; PPIs are inherently per-CPU already and
 * need no such thing) BEFORE its ISENABLER bit is set, or QEMU's own
 * arm_gic.c computes the per-CPU enable mask from whatever target was
 * configured AT ENABLE TIME (0 by default, i.e. no CPU) and the
 * interrupt never becomes deliverable even though it looks "enabled"
 * -- confirmed empirically (a round-trip echo test sent real bytes
 * over stdin that a temporary polling probe proved genuinely reached
 * the PL011's RX FIFO, but the interrupt path never fired, tracing
 * back to this exact gap) before reading arm_gic.c's own dist_writeb
 * handler to find why. Both registers are ordinary MMIO, so vani code
 * can set them directly via mmio_write_u32 with no new assembly
 * needed -- see that function's own comment for the two writes and
 * their order. */
.global gic_timer_init
gic_timer_init:
    stp x29, x30, [sp, #-16]!

    ldr x0, =GICD_BASE
    mov w1, #1
    str w1, [x0, #GICD_CTLR]

    mov w1, #(1 << 30)
    str w1, [x0, #GICD_ISENABLER0]

    ldr x0, =GICC_BASE
    mov w1, #0xFF
    str w1, [x0, #GICC_PMR]

    mov w1, #1
    str w1, [x0, #GICC_CTLR]
    isb

    bl gic_timer_rearm

    ldp x29, x30, [sp], #16
    ret

/* Re-arms the timer for another CNTFRQ_EL0/2-tick period and ensures
 * it's enabled -- called both by gic_timer_init (first arm) and by
 * the IRQ handler after each firing (so the heartbeat is genuinely
 * periodic, not one-shot). Leaf function: only touches x0/x1. */
.global gic_timer_rearm
gic_timer_rearm:
    mrs x0, cntfrq_el0
    lsr x0, x0, #1
    msr cntp_tval_el0, x0
    mov x1, #1
    msr cntp_ctl_el0, x1
    isb
    ret

/* Disables the timer outright (ENABLE=0) -- used once this round's
 * own smoke-test milestone (a bounded number of ticks, see vectors.S)
 * has proven the round trip and wants a clean, quiet halt afterward
 * rather than continuing to fire forever. */
.global gic_timer_disable
gic_timer_disable:
    msr cntp_ctl_el0, xzr
    isb
    ret
