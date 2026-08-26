/* Dhruva Phase 1 -- cooperative context switch (ARM32 / AAPCS).
 *
 * Shared across every ARM32 board (Pi 1/2/3 in 32-bit mode, PandaBoard) --
 * the calling convention this relies on (r4-r11 + lr are callee-saved,
 * everything else the compiler already treats as clobbered across a
 * function call) is architecture-level, not board-level. AArch64 boards
 * (Pi 3/4/5 in 64-bit mode) will need a different version of this file
 * with the AArch64 callee-saved set (x19-x30) -- not written yet, since
 * Phase 0/1 only target Pi 1 (ARMv6, no 64-bit mode exists on that core).
 *
 * Why this can't be vani: a task-to-task context switch fundamentally
 * needs to save/restore raw CPU registers and swap the live stack
 * pointer mid-function -- there's no way to express that in any
 * high-level language's normal control flow, vani included. Same
 * documented exception as boot.S (see architecture doc SS5).
 *
 * Why the scheduler's tiny bit of persistent state (sp_table,
 * current_task) lives here in assembly .bss rather than as vani
 * variables: vani has no top-level static/global variable mechanism
 * (verified against the language manual and compiler source before
 * writing this) -- by design, matching its ownership model, which
 * doesn't want unscoped shared mutable state. A hand-written assembly
 * file has no such restriction. This keeps the exception narrowly
 * scoped to "the scheduler's raw save-slots," not general kernel state --
 * everything else (task bodies, the print loop, printing decisions)
 * stays in kernel_main.vani.
 *
 * Real, load-bearing limitation this design works around: vani has no
 * way to take the address of a function (confirmed empirically -- `f as
 * i64` on a `fn() -> i64` value is rejected by the checker as an
 * unrelated-type cast, and there is no builtin for it either). A
 * general "spawn task at this entry point" API would need that. Until
 * vani gains function-pointer support, each task needs its own named
 * *_init_stack stub below, hardcoded to its entry function by symbol
 * name at the assembly level -- fine for Phase 1's fixed, small task
 * count, a real constraint worth solving later for anything more
 * general.
 */

.section ".bss"
.align 4
sp_table:
    .word 0, 0      /* sp_table[0] = task_a's saved sp, [1] = task_b's */
current_task:
    .word 0         /* index into sp_table of the task now running */

.section ".text"

/* void yield_now(void)
 * Saves the calling task's context, switches to the other of the two
 * known tasks, and returns (into that other task, or -- for its very
 * first activation -- jumps to its entry point instead of returning,
 * indistinguishably from this function's caller's point of view). */
.global yield_now
yield_now:
    push {r4-r11, lr}
    ldr r2, =current_task
    ldr r3, [r2]
    ldr r4, =sp_table
    mov r5, sp
    str r5, [r4, r3, lsl #2]   /* sp_table[current_task] = my sp */
    eor r3, r3, #1             /* only two tasks: toggle 0<->1 */
    str r3, [r2]
    ldr sp, [r4, r3, lsl #2]   /* sp = sp_table[other] */
    pop {r4-r11, lr}
    bx lr

/* *mut i64 task_a_init_stack(*mut i64 stack_base, i64 stack_bytes)
 * *mut i64 task_b_init_stack(*mut i64 stack_base, i64 stack_bytes)
 * Builds the fake initial register frame at the top of a fresh stack
 * region so yield_now's restore half (pop {r4-r11,lr}; bx lr) can
 * bootstrap a never-before-run task exactly like it resumes one that
 * has: r4-r11 don't matter yet (zeroed), lr = the task's real entry
 * point, so "returning" into this fake frame for the first time is
 * indistinguishable from a normal resume.
 *
 * ABI note (found the hard way, first real QEMU boot): vani's `i64` is
 * a genuine 64-bit value, and AAPCS passes a 64-bit argument in a
 * register PAIR, not one register -- so stack_base is r0:r1 (r0=low,
 * r1=high, always 0 for any real 32-bit address) and stack_bytes is
 * r2:r3, NOT r1 as a naive "one arg = one register" reading would
 * assume. Every function below only ever touches the low register of
 * each pair and ignores the high one, which is safe and self-consistent
 * as long as every value passed through this whole file stays within
 * 32 bits -- true for every address/byte-count/index Dhruva deals with
 * on this 32-bit target, but a real, load-bearing assumption worth
 * stating plainly rather than leaving implicit. */
.global task_a_init_stack
task_a_init_stack:
    add r0, r0, r2      /* stack_bytes is r2 (r1 is stack_base's high word) */
    ldr r1, =task_a
    b prepare_stack_common

.global task_b_init_stack
task_b_init_stack:
    add r0, r0, r2
    ldr r1, =task_b
    b prepare_stack_common

prepare_stack_common:
    sub r0, r0, #36      /* room for r4-r11 + lr, 9 words */
    mov r2, #0
    str r2, [r0, #0]
    str r2, [r0, #4]
    str r2, [r0, #8]
    str r2, [r0, #12]
    str r2, [r0, #16]
    str r2, [r0, #20]
    str r2, [r0, #24]
    str r2, [r0, #28]
    str r1, [r0, #32]    /* lr slot = entry point */
    bx lr

/* i64 start_multitasking(i64 sp_a, i64 sp_b)
 * Seeds the scheduler state and jumps into task_a for the first time.
 * Never returns in the Phase 1 demo (both tasks loop forever).
 *
 * Two i64 args -> AAPCS register pairs: sp_a is r0:r1, sp_b is r2:r3
 * (not r1 -- same register-pairing gotcha as above). r2 must be saved
 * off before it gets clobbered by loading sp_table's address; r4 is a
 * safe scratch register here since the pop just below overwrites it
 * anyway when it restores task_a's fake initial frame. */
.global start_multitasking
start_multitasking:
    mov r4, r2             /* save sp_b (r2) before r2 gets reused below */
    ldr r2, =sp_table
    str r0, [r2, #0]       /* sp_table[0] = sp_a */
    str r4, [r2, #4]       /* sp_table[1] = sp_b */
    ldr r3, =current_task
    mov r5, #0
    str r5, [r3]
    mov sp, r0
    pop {r4-r11, lr}
    bx lr
