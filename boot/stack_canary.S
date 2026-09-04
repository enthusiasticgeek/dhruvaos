/* Dhruva -- per-task stack overflow canary (ARM32).
 *
 * This project's task stacks are plain sequential dhruva_alloc_bytes
 * heap allocations with no MMU guard page between them. The current
 * MMU setup (mmu_init.S) only has 1MB SECTION granularity -- .data/
 * .bss/heap/every task stack all share ONE 1MB section with uniform
 * read+write permissions, so a real guard page would need second-
 * level 4KB page tables, which is out of scope here (flagged in
 * docs/TODO.md as real future work; see mmu_init.S's own header for
 * why the current table can't express anything finer than 1MB).
 *
 * Without that, a task that overflows its own allocated stack today
 * silently corrupts whatever memory sits immediately below it (the
 * previous stack in allocation order) with NO detection at all --
 * until the corruption eventually manifests as an unrelated-looking
 * crash somewhere completely different, arbitrarily far downstream in
 * both time and call depth. That's exactly the failure mode this
 * file's own kernel_main.vani comments document hitting FOUR separate
 * times already (task_f round 9, task_e round 27, task_custom_demo
 * round 60, task_f again round 67 for tlsecho) -- each one only ever
 * "fixed" by empirically raising a real stack allocation past
 * whatever the static #[bounded_stack] checker (itself documented as
 * "a conservative estimator, not an exact analysis") claimed was
 * enough, with nothing structural added to catch the NEXT occurrence
 * early. This is that structural piece.
 *
 * Doesn't PREVENT overflow (only a real guard page could) -- it
 * plants a known sentinel word at the very base (lowest address, the
 * first byte a full-descending stack's overflow would reach) of every
 * task's stack at boot, and gives irq_dispatch a cheap, O(task count)
 * way to check all of them once per real timer tick (the same ~500ms
 * cadence diag_ring already samples at). A breach isn't caught at the
 * exact instruction that caused it, but it's caught within one tick
 * of it happening, and names the exact task -- turning "wild pointer
 * crash in a totally unrelated call chain, hours of GDB required"
 * into "task_f's stack canary broke at tick N," which is what every
 * one of those four historical incidents actually needed from the
 * start.
 *
 * Indexed by task ID: 0-5 are task_a..task_f (context_switch.S's own
 * sp_table order), 6-9 are the four task_create'd tasks in the exact
 * order kernel_main() creates them (custom_demo, mutex_demo_low,
 * mutex_demo_high, fsqueue) -- matches task_create's own sequential
 * free-slot assignment starting at 6. 16 slots total to match
 * context_switch.S's own MAX_TASKS, though only the first 10 are ever
 * populated as of this round; a future task_create caller beyond that
 * simply never gets a tracked canary, same as it already gets no
 * #[bounded_stack] checking today. */

.section ".bss"
.align 4
stack_canary_table:
    .space 64   /* 16 x 4-byte stack-base pointers; 0 = untracked */

.section ".text"

.equ CANARY_SENTINEL, 0xDEADC0DE

/* i64 stack_canary_set_base(u32 index, mut ref i64 base) -- records
 * base as task `index`'s tracked stack, and plants the sentinel at
 * base[0]. Must be called once per task, at boot, right after that
 * task's stack is allocated -- and before start_multitasking, so the
 * sentinel is in place before anything could possibly overflow into
 * it. Both parameters are single-register (u32 index, plain pointer),
 * so no AAPCS register-pairing gotcha here -- see dharafs_buf.S's own
 * file comment for why every function in this project's accessor
 * files deliberately avoids i64 parameters for exactly this reason. */
.global stack_canary_set_base
stack_canary_set_base:
    ldr r2, =stack_canary_table
    str r1, [r2, r0, lsl #2]
    ldr r2, =CANARY_SENTINEL
    str r2, [r1]
    mov r0, #0
    bx lr

/* u32 stack_canary_check_all() -- returns a bitmask, one bit per task
 * index (bit i set means task i's canary is broken). 0 = every
 * tracked stack's sentinel is still intact. Untracked (never-set)
 * slots are skipped, not flagged. Uses r4-r6 as loop scratch, so it
 * must (and does) save/restore them -- an unsaved-callee-register
 * clobber here would silently corrupt whatever live value the vani-
 * compiled caller (irq_dispatch) happened to be keeping in the same
 * register, the same AAPCS callee-saved-register bug class this
 * project has been bitten by before in other hand-written ARM32 asm. */
.global stack_canary_check_all
stack_canary_check_all:
    stmdb sp!, {r4-r6, lr}
    ldr r4, =stack_canary_table
    mov r5, #0              /* task index */
    mov r6, #0              /* result bitmask */
stack_canary_check_loop:
    cmp r5, #16
    bge stack_canary_check_done
    ldr r0, [r4, r5, lsl #2]
    cmp r0, #0
    beq stack_canary_check_next
    ldr r1, [r0]
    ldr r2, =CANARY_SENTINEL
    cmp r1, r2
    beq stack_canary_check_next
    mov r3, #1
    orr r6, r6, r3, lsl r5
stack_canary_check_next:
    add r5, r5, #1
    b stack_canary_check_loop
stack_canary_check_done:
    mov r0, r6
    ldmia sp!, {r4-r6, lr}
    bx lr
