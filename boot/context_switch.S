/* Dhruva Phase 2 -- preemptive round-robin between two tasks (ARM32).
 *
 * Supersedes Phase 1's yield_now-only cooperative design: task_a/
 * task_b no longer call anything to give up the CPU -- the timer tick
 * (boot/irq_entry.S) does it for them, at whatever instruction they
 * happen to be at. That's the actual difference between "cooperative"
 * and "preemptive," and it's why irq_entry.S now saves the full
 * register set (r0-r12) instead of just the callee-saved set Phase 1's
 * yield_now relied on AAPCS for -- see irq_entry.S's own comment for
 * why that distinction matters here specifically.
 *
 * Why the scheduler's tiny bit of persistent state (sp_table,
 * current_task) still lives here in assembly .bss rather than as vani
 * variables: unchanged from Phase 1 -- vani has no top-level static/
 * global variable mechanism, by design, matching its ownership model.
 *
 * Still using named per-task init-stack stubs (task_a_init_stack /
 * task_b_init_stack) rather than one generic one taking a function
 * pointer: vani CAN pass a named function where a parameter's type is
 * itself `fn() -> i64` (confirmed working, see kernel_main.vani's
 * comment), but a generic `task_init_stack(base, bytes, entry)` needs
 * a three-argument mixed ref+i64+fnptr signature whose combined
 * register/stack-spill layout hasn't been verified yet -- not a
 * limitation, just not done. Worth doing before task count grows past
 * a handful.
 */

.section ".bss"
.align 4
sp_table:
    .word 0, 0      /* sp_table[0] = task_a's saved sp, [1] = task_b's */
current_task:
    .word 0         /* index into sp_table of the task now running */

.section ".text"

/* void *scheduler_switch_from_irq(void *current_sp)
 * Called only from boot/irq_entry.S, after it has already saved the
 * interrupted task's full context onto its own stack. Records that
 * context as the current task's new resume point, picks the other of
 * the two known tasks (plain round-robin -- real priority-based
 * selection is a later step), and returns its saved sp. A pure data
 * operation: no registers beyond r0-r3 are touched, which is safe
 * because the caller has already preserved everything that matters on
 * the stack before calling this. */
.global scheduler_switch_from_irq
scheduler_switch_from_irq:
    ldr r1, =current_task
    ldr r2, [r1]
    ldr r3, =sp_table
    str r0, [r3, r2, lsl #2]   /* sp_table[current_task] = current_sp */
    eor r2, r2, #1              /* only two tasks: toggle 0<->1 */
    str r2, [r1]
    ldr r0, [r3, r2, lsl #2]   /* r0 = sp_table[new current] */
    bx lr

/* mut ref i64 task_a_init_stack(mut ref i64 stack_base, i64 stack_bytes)
 * mut ref i64 task_b_init_stack(mut ref i64 stack_base, i64 stack_bytes)
 * Builds a fake initial context at the top of a fresh stack region,
 * shaped to match exactly what irq_entry.S's restore sequence expects
 * (spsr, pad, r0-r12, lr, in that order from low to high address) --
 * so resuming a never-before-run task via the timer path is
 * indistinguishable from resuming one that's genuinely been
 * interrupted before. spsr is set to 0x13 (SVC mode, IRQ/FIQ enabled,
 * ARM state) rather than left zero: zero decodes to a reserved/invalid
 * mode field, which would corrupt CPSR the instant this task is first
 * resumed. r0-r12 don't matter yet (zeroed); lr is the task's real
 * entry point. */
.global task_a_init_stack
task_a_init_stack:
    add r0, r0, r2      /* stack_top = stack_base + stack_bytes; stack_bytes
                          * is r2 because a ref arg (stack_base) is one
                          * register, but stack_bytes (a plain i64) still
                          * gets AAPCS's 64-bit-argument register-pair
                          * treatment -- see kernel_main.vani's comment */
    ldr r1, =task_a
    b prepare_stack_common

.global task_b_init_stack
task_b_init_stack:
    add r0, r0, r2
    ldr r1, =task_b
    b prepare_stack_common

prepare_stack_common:
    sub r0, r0, #64       /* room for spsr, pad, r0-r12, lr -- 16 words */
    mov r2, #0x13         /* SVC mode, IRQ/FIQ enabled, ARM state */
    str r2, [r0, #0]      /* spsr slot */
    mov r2, #0
    str r2, [r0, #4]      /* pad */
    str r2, [r0, #8]      /* r0 */
    str r2, [r0, #12]     /* r1 */
    str r2, [r0, #16]     /* r2 */
    str r2, [r0, #20]     /* r3 */
    str r2, [r0, #24]     /* r4 */
    str r2, [r0, #28]     /* r5 */
    str r2, [r0, #32]     /* r6 */
    str r2, [r0, #36]     /* r7 */
    str r2, [r0, #40]     /* r8 */
    str r2, [r0, #44]     /* r9 */
    str r2, [r0, #48]     /* r10 */
    str r2, [r0, #52]     /* r11 */
    str r2, [r0, #56]     /* r12 */
    str r1, [r0, #60]     /* lr = entry point */
    bx lr

/* i64 start_multitasking(mut ref i64 sp_a, mut ref i64 sp_b)
 * Seeds the scheduler state and enters task_a for the first time,
 * via the exact same spsr-restoring return irq_entry.S uses -- valid
 * here too, even though this isn't an actual exception return: SVC
 * mode has its own banked SPSR regardless of why something writes to
 * it, and kernel_main (which calls this) runs in SVC mode. Never
 * returns in practice -- both tasks run forever, traded off by the
 * timer tick from here on. */
.global start_multitasking
start_multitasking:
    ldr r2, =sp_table
    str r0, [r2, #0]
    str r1, [r2, #4]
    ldr r3, =current_task
    mov r4, #0
    str r4, [r3]
    mov sp, r0
    ldmia sp!, {r0, r1}
    msr spsr_cxsf, r0
    ldmia sp!, {r0-r12, lr}
    subs pc, lr, #0
