/* Dhruva -- persistent scratch buffers for the crash log (any real
 * fault -- Data Abort, Prefetch Abort -- gets a small diagnostic
 * record written to DharaFS before the system halts, so it survives
 * past the halt for later diagnosis instead of only ever reaching a
 * UART console nobody may be watching at the exact moment of a crash).
 *
 * Deliberately its OWN small file, not reusing scratch_state.S's own
 * buffers: that file's own safety reasoning ("task_e and task_f are
 * the only two tasks that ever touch any of them... neither sleeps
 * mid-call") is specific to those two tasks' own non-preemptive
 * calling discipline. A fault can interrupt ANY task at ANY point --
 * these buffers are used only from the fault-report path itself,
 * which runs once and halts the whole system immediately after, so
 * aliasing with whatever a normal task was doing at the moment of the
 * fault is harmless in practice (nothing resumes afterward to be
 * confused by it), but giving them their own name avoids implying the
 * same "only two well-behaved tasks touch this" guarantee that
 * doesn't actually hold here. */

.section ".bss"
.align 4
crashlog_record_scratch_addr:  .word 0   /* 56 bytes: one crash record,
                                          * see kernel_main.vani's own
                                          * crashlog_record_crash for
                                          * the exact field layout */
crashlog_meta_scratch_addr:    .word 0   /* 8 bytes: [total_crash_count_
                                          * ever: u32][boot_count: u32] */
crashlog_path_scratch_addr:    .word 0   /* 32 bytes: "/crashlogNN" --
                                          * DharaFS's own 32-byte path
                                          * limit */

.section ".text"

.macro CRASHLOG_SCRATCH_PAIR name
.global \name\()_set
\name\()_set:
    ldr r1, =\name\()_addr
    str r0, [r1]
    mov r0, #0
    bx lr

.global \name\()_get
\name\()_get:
    ldr r0, =\name\()_addr
    ldr r0, [r0]
    bx lr
.endm

CRASHLOG_SCRATCH_PAIR crashlog_record_scratch
CRASHLOG_SCRATCH_PAIR crashlog_meta_scratch
CRASHLOG_SCRATCH_PAIR crashlog_path_scratch
