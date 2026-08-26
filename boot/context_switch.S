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
 * ABI note, corrected 2026-08-25: every address crossing into this file
 * from vani is `mut ref i64`, not a bare `i64` (initial versions used
 * plain i64 out of a wrong assumption that raw pointer types couldn't
 * cross extern "C" at all -- disproven by testing the actual LLVM IR,
 * where `mut ref i64` lowers to plain `i64*`, always exactly one
 * register). This matters here specifically because vani's `i64` is a
 * genuine 64-bit value and AAPCS passes a 64-bit *scalar* argument as a
 * register PAIR with alignment padding, which silently shifts later
 * arguments by a register -- the exact bug that first broke this file
 * (a plain-i64 stack_bytes argument was assumed to be in r1, but a
 * preceding i64 stack_base argument pushed it to r2). A `mut ref i64`
 * pointer argument never has this problem: always one register,
 * regardless of what precedes it. `stack_bytes` below is still a plain
 * `i64` (a byte count, not an address) and still needs the pairing rule
 * accounted for -- that part of the original finding still applies and
 * is not a mistake to walk back.
 *
 * Real, load-bearing limitation this design still works around: vani
 * has no way to take the address of a function as data (confirmed
 * empirically -- `f as i64` on a `fn() -> i64` value is rejected as an
 * unrelated-type cast). It *can*, however, pass a named function
 * directly where an extern parameter's declared type is itself
 * `fn() -> i64` (confirmed: this lowers to a plain function-pointer
 * argument, one register). That would allow a single generic
 * `task_init_stack(stack_base, stack_bytes, entry)` instead of one
 * named stub per task -- not done yet, since mixing a `mut ref i64`, a
 * plain `i64`, and a `fn() -> i64` in one signature raises the register/
 * stack-spill layout past what's been verified here, and Phase 1's two
 * hardcoded tasks don't need it yet. Worth doing before task count grows
 * past a handful.
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

/* mut ref i64 task_a_init_stack(mut ref i64 stack_base, i64 stack_bytes)
 * mut ref i64 task_b_init_stack(mut ref i64 stack_base, i64 stack_bytes)
 * Builds the fake initial register frame at the top of a fresh stack
 * region so yield_now's restore half (pop {r4-r11,lr}; bx lr) can
 * bootstrap a never-before-run task exactly like it resumes one that
 * has: r4-r11 don't matter yet (zeroed), lr = the task's real entry
 * point, so "returning" into this fake frame for the first time is
 * indistinguishable from a normal resume.
 *
 * stack_base (a ref/pointer) is exactly one register: r0. stack_bytes
 * (a plain i64) still gets AAPCS's 64-bit-argument treatment -- aligned
 * to the next even register, which means it lands in r2:r3, not r1.
 * r1 is simply unused here (it would be stack_base's "high word" under
 * the old plain-i64 design; under a ref it's not even that, just a
 * padding gap AAPCS leaves for the i64 alignment rule). Return value is
 * a ref too, so it's one register (r0) on the way out as well -- no
 * pairing concern in either direction. */
.global task_a_init_stack
task_a_init_stack:
    add r0, r0, r2      /* stack_top = stack_base + stack_bytes */
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

/* i64 start_multitasking(mut ref i64 sp_a, mut ref i64 sp_b)
 * Seeds the scheduler state and jumps into task_a for the first time.
 * Never returns in the Phase 1 demo (both tasks loop forever).
 *
 * Two ref args, each exactly one register, land in r0 and r1
 * consecutively -- no alignment/pairing gap, unlike two plain i64 args
 * (which would put the second one in r2:r3, as the earlier plain-i64
 * version of this function had to work around). This is the version
 * that's actually simpler than what it replaced. */
.global start_multitasking
start_multitasking:
    ldr r2, =sp_table
    str r0, [r2, #0]       /* sp_table[0] = sp_a */
    str r1, [r2, #4]       /* sp_table[1] = sp_b */
    ldr r3, =current_task
    mov r4, #0
    str r4, [r3]
    mov sp, r0
    pop {r4-r11, lr}
    bx lr
