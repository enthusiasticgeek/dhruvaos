/* Dhruva round 78 -- the smallest possible proof of an ARMv8-A
 * context switch on the Pi 4/5 port. Deliberately NOT the real
 * scheduler (no preemption, no priorities, no timer-IRQ integration)
 * -- proves the one genuinely new AArch64-specific primitive any real
 * scheduler on this target would need first: that two independent
 * stacks can be built and swapped between correctly. This is a
 * cooperative (voluntary-yield) switch, not the interrupt-driven kind
 * Pi 1's own boot/context_switch.S uses -- deliberately so, to keep
 * this round's own surface small and separate from the already-
 * delicate timer-IRQ path (round 75/77's own AAPCS-callee-saved-
 * register lessons argue for touching that path as little as
 * possible until this primitive is proven on its own first).
 *
 * task_switch(save_to, load_from) saves the CALLER's own callee-saved
 * registers (AAPCS64: x19-x28, x29/fp, x30/lr) onto the caller's
 * current stack, records that stack pointer at *save_to, then loads
 * the stack pointer from *load_from and restores ITS callee-saved
 * registers before returning -- the classic "swap stacks" cooperative
 * switch, the same shape as any textbook fiber/coroutine
 * implementation. x0-x18 (caller-saved) and NZCV are NOT preserved --
 * by AAPCS64's own contract, a function call may already clobber
 * these, so nothing calling task_switch (an ordinary `bl`) can be
 * relying on them surviving anyway.
 *
 * task_a_stack_init/task_b_stack_init each build a fake saved-frame
 * on their own static stack, shaped identically to what task_switch
 * itself pushes, with the saved x30 (LR) pointing at that task's own
 * vani entry function -- so the FIRST switch into a task "returns"
 * (via task_switch's own `ret`) directly into that function. Each
 * hardcodes its own entry point via `adr` rather than accepting one
 * as a parameter -- these two tasks are fixed and known at build
 * time, so there's no need for (and vani has no established
 * convention for passing) a general function-pointer value here.
 * task_a_vani_entry/task_b_vani_entry (kernel_main_rpi4.vani) must
 * never actually `ret` from that first entry -- there is no real
 * caller frame below this synthetic one -- they only ever leave via
 * another task_switch call.
 */
.section ".bss"
.align 4
task_a_sp: .quad 0
task_b_sp: .quad 0
boot_sp: .quad 0
switch_count: .quad 0
.align 4
task_a_stack: .space 1024
task_a_stack_top:
task_b_stack: .space 1024
task_b_stack_top:

.section ".text"

/* void task_switch(uint64_t *save_to, uint64_t *load_from) */
.global task_switch
task_switch:
    stp x19, x20, [sp, #-96]!
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp x27, x28, [sp, #64]
    stp x29, x30, [sp, #80]

    mov x2, sp
    str x2, [x0]

    ldr x2, [x1]
    mov sp, x2

    ldp x29, x30, [sp, #80]
    ldp x27, x28, [sp, #64]
    ldp x25, x26, [sp, #48]
    ldp x23, x24, [sp, #32]
    ldp x21, x22, [sp, #16]
    ldp x19, x20, [sp], #96
    ret

/* task_switch's own `stp x29, x30, [sp, #80]` puts x29 at +80 and x30
 * (LR -- the slot that actually matters here) at +88; the matching
 * `ldp x29, x30, [sp, #80]` reads them back the same way. The entry
 * address must land at +88, not +80. */
.global task_a_stack_init
task_a_stack_init:
    ldr x0, =task_a_stack_top
    sub x0, x0, #96
    adr x1, task_a_vani_entry
    str x1, [x0, #88]
    ldr x1, =task_a_sp
    str x0, [x1]
    ret

.global task_b_stack_init
task_b_stack_init:
    ldr x0, =task_b_stack_top
    sub x0, x0, #96
    adr x1, task_b_vani_entry
    str x1, [x0, #88]
    ldr x1, =task_b_sp
    str x0, [x1]
    ret

/* Plain address-of accessors -- vani has no top-level global-variable
 * mechanism, same reason every other piece of persistent state in
 * this project (both Pi 1 and Pi 4/5 sides) goes through one of
 * these. */
.global task_a_sp_addr
task_a_sp_addr:
    ldr x0, =task_a_sp
    ret

.global task_b_sp_addr
task_b_sp_addr:
    ldr x0, =task_b_sp
    ret

.global boot_sp_addr
boot_sp_addr:
    ldr x0, =boot_sp
    ret

.global switch_count_increment
switch_count_increment:
    ldr x0, =switch_count
    ldr x1, [x0]
    add x1, x1, #1
    str x1, [x0]
    mov x0, x1
    ret
