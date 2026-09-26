/* 2026-09-26: ARM1176JZF-S Performance Monitor cycle counter (PMCCNTR).
 * Real RTOS-compliance gap (docs/RTOS_GAP_ANALYSIS.md, section 4,
 * "SD command-level timeouts... aren't tied into a documented
 * worst-case latency contract"): sdhost_cmd's own 1,000,000-iteration
 * poll cap has never had a real absolute-time bound computed for it,
 * only an iteration count -- the document's own words: "this project
 * has no cycle counter wired up anywhere to measure it... Presenting
 * a specific millisecond figure without that would be false
 * precision." This closes exactly that gap.
 *
 * ARM1176JZF-S predates the ARMv7 PMU (CP15 c9) -- its performance
 * monitor unit lives at CP15 c15, a different, implementation-defined
 * encoding specific to this core (confirmed against the ARM1176JZF-S
 * Technical Reference Manual's own "Performance monitor register
 * summary" table, not guessed):
 *   PMNC (Performance Monitor Control Register): p15, 0, Rd, c15, c12, 0
 *   CCNT (Cycle Count Register):                 p15, 0, Rd, c15, c12, 1
 * PMNC bit fields used here: bit0 E (enable all counters), bit1 P
 * (reset PMN0/PMN1, harmless/unused here), bit2 C (reset CCNT), bit3 D
 * (0 = count every cycle for maximum precision; 1 would divide by 64).
 * Writing 0b0111 = 0x7 enables counting and resets CCNT to 0 in one
 * write.
 *
 * Whether QEMU's own arm1176 CPU model actually implements these CP15
 * c15 registers (as opposed to real ARM1176JZF-S silicon, where they
 * are architecturally guaranteed) is unconfirmed as of this writing --
 * this is exactly the kind of thing to verify empirically (build,
 * boot under QEMU, see whether the self-test's own cross-check
 * against TIMER_CLO reports a plausible clock rate) rather than
 * assume either way. */

.section ".text"

/* i64 pmccntr_enable() -- enables the cycle counter and resets it to
 * 0. Returns 0 always (no failure mode to report -- an MCR to an
 * unimplemented CP15 register on this core class is defined to be a
 * silent no-op, not an undefined-instruction trap, per the same TRM;
 * the self-test's own cross-check against TIMER_CLO is what actually
 * proves whether this had any real effect). */
.global pmccntr_enable
pmccntr_enable:
    mov r0, #7
    mcr p15, 0, r0, c15, c12, 0
    mov r0, #0
    mov r1, #0
    bx lr

/* u32 pmccntr_read() -- current cycle count. */
.global pmccntr_read
pmccntr_read:
    mrc p15, 0, r0, c15, c12, 1
    bx lr
