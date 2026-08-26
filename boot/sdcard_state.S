/* Dhruva Phase 3 -- tiny persistent SD-card state (ARM32).
 *
 * vani has no top-level global/static variables by design (see
 * kernel_main.vani's own header) -- kernel_main.vani's sdhost_init()
 * runs exactly once, but the RCA it publishes and the card's
 * addressing mode (SDSC/byte-addressed vs SDHC/block-addressed, from
 * the OCR's CCS bit) need to reach every later block read/write call,
 * including from a future GC/compaction task's own function body
 * (task #5) -- a separate entry point kernel_main's local variables
 * can't reach. Exactly the same shape of problem context_switch.S's
 * sp_table/current_task already solve for scheduler state, so this
 * follows the same small-.bss-plus-extern-accessor pattern rather
 * than inventing a second way to persist state across a vani call
 * boundary.
 */

.section ".bss"
.align 4
sd_rca:
    .word 0        /* published by CMD3, needed by every addressed
                     * command (CMD9/CMD7/CMD17/CMD24) from here on */
sd_is_sdhc:
    .word 0        /* 0 = SDSC (byte-addressed), 1 = SDHC/SDXC
                     * (block-addressed) -- from the OCR's CCS bit,
                     * valid only once ACMD41 reports busy=0 (ready) */

.section ".text"

/* Every function below that uses r4 or r5 as scratch now saves and
 * restores it (push/pop) -- not defensive filler, a fix for a real
 * bug: r4-r11 are callee-saved under AAPCS, and vani's generated
 * caller code keeps genuinely live values in them across calls on the
 * strength of that guarantee (confirmed directly in kernel_main's own
 * disassembly, which holds buffer pointers and later start_
 * multitasking's own arguments in r4-r9 across this exact block of
 * calls). Clobbering r4/r5 here without saving them doesn't corrupt
 * anything the compiler can see -- it corrupts values the compiler
 * has every right to assume survive untouched, which is a fundamentally
 * different, much harder to see class of bug than a wrong local
 * computation: the visible failure lands wherever that clobbered
 * register's value next gets used, often far away in unrelated code.
 * Here specifically, that meant a second consecutive SD read/write
 * cycle would run and report success individually, exactly as
 * expected, and the actual damage -- corrupted task-stack-pointer
 * arguments reaching start_multitasking -- wouldn't surface as a
 * crash until real preemption began running task code against those
 * bad pointers, well after the SD code had already finished and moved
 * on. Confirmed via `qemu-system-arm -d int,cpu_reset`: zero real
 * reset events logged despite the visible reboot, meaning this was
 * PC jumping back to _start from corrupted state, the same signature
 * boot/irq_entry.S's unrelated Phase 2 bug had -- and via bisection
 * showing one SD read/write cycle was always safe while a second one,
 * regardless of which block number either touched, reliably wasn't.
 *
 * Every function below is declared in kernel_main.vani as returning
 * `i64` -- a genuine 64-bit AAPCS return value, back in r0:r1 (low:
 * high), not just r0. Explicitly zeroing r1 before every `bx lr` here
 * is not defensive-programming filler: leaving it unset (whatever a
 * function happened to last use r1 for) is a real, reproducible bug
 * class, not just a theoretical ABI nicety -- see test_compare_buffers
 * below for the instance that actually manifested, corrupting a
 * caller's own multi-term boolean logic despite the caller's own code
 * and vani's compiler both being entirely correct. */
.global sd_state_set
sd_state_set:
    ldr r2, =sd_rca
    str r0, [r2]
    ldr r2, =sd_is_sdhc
    str r1, [r2]
    mov r0, #0
    mov r1, #0
    bx lr

.global sd_state_get_rca
sd_state_get_rca:
    ldr r0, =sd_rca
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global sd_state_get_is_sdhc
sd_state_get_is_sdhc:
    ldr r0, =sd_is_sdhc
    ldr r0, [r0]
    mov r1, #0
    bx lr

/* void sdhost_drain_fifo_to_buffer(mut ref i64 buf, i64 word_count)
 * void sdhost_fill_fifo_from_buffer(mut ref i64 buf, i64 word_count)
 *
 * The one piece of Phase 3's SD driver vani genuinely can't express:
 * transferring raw 32-bit words between the SDDATA FIFO register and
 * an arbitrary caller-supplied buffer address. vani's mmio_read_u32/
 * mmio_write_u32 builtins take a literal i64 address, not a `mut ref
 * i64` handle -- there is no vani-level operation that turns a
 * reference into a plain integer address to feed them (by design,
 * same reasoning as every other raw-pointer gap this project has hit:
 * a first-class reference degrading to a bare address would break the
 * ownership model). So, same as context_switch.S's stack-frame
 * plumbing, this one small raw-memory loop lives in hand-written
 * assembly; the actual SD command/protocol logic (which only ever
 * needs plain scalar values) stays in kernel_main.vani, calling these
 * only for the FIFO-to-RAM leg of a transfer.
 *
 * word_count arrives in r2, NOT r1: this project's own established
 * AAPCS gotcha (see context_switch.S/task_sleep_ticks) is that a
 * 64-bit i64 argument needs an even-aligned register pair, and a
 * preceding `mut ref i64` (1 register, r0) leaves the next slot at
 * the ODD position r1 -- so the real ABI pads r1 and places word_count
 * at r2:r3 instead. Confirmed directly from the compiled callsite
 * disassembly (`mov r2, #128; mov r3, #0; bl ...`) after this exact
 * bug produced a genuinely erratic symptom: reading stale, unrelated
 * garbage out of r1 as the loop count -- sometimes small enough to
 * merely transfer the wrong number of words (silently, since QEMU's
 * SD emulation doesn't fail loudly on a short transfer), sometimes
 * large enough to spin for what looks exactly like an infinite hang.
 * Both symptoms, and their apparent sensitivity to unrelated code
 * changes elsewhere (different register allocation nearby just
 * happened to leave different garbage in r1), pointed at a genuine
 * calling-convention bug here rather than an SD-protocol one, once
 * actually checked against the disassembly instead of guessed at from
 * symptoms alone. */
.global sdhost_drain_fifo_to_buffer
sdhost_drain_fifo_to_buffer:
    push {r4}                /* r4 is callee-saved (AAPCS) -- see the
                               * file-level note below on why this
                               * isn't optional here */
    mov r4, r2               /* r4 = word_count (r2:r3 pair, low half) */
    ldr r2, =0x20202040     /* SDDATA */
sdhost_drain_loop:
    cmp r4, #0
    beq sdhost_drain_done
    ldr r3, [r2]
    str r3, [r0], #4
    sub r4, r4, #1
    b sdhost_drain_loop
sdhost_drain_done:
    pop {r4}
    mov r0, #0
    mov r1, #0
    bx lr

.global sdhost_fill_fifo_from_buffer
sdhost_fill_fifo_from_buffer:
    push {r4}
    mov r4, r2               /* r4 = word_count (r2:r3 pair, low half) */
    ldr r2, =0x20202040     /* SDDATA */
sdhost_fill_loop:
    cmp r4, #0
    beq sdhost_fill_done
    ldr r3, [r0], #4
    str r3, [r2]
    sub r4, r4, #1
    b sdhost_fill_loop
sdhost_fill_done:
    pop {r4}
    mov r0, #0
    mov r1, #0
    bx lr

/* TEST-ONLY (round-trip verification for task #3, not part of the
 * driver proper): fill a buffer with a byte pattern (index & 0xFF),
 * and compare two buffers byte-for-byte.
 * void test_fill_pattern(mut ref i64 buf, i64 byte_count)
 * i64 test_compare_buffers(mut ref i64 a, mut ref i64 b, i64 byte_count)
 *   -- returns 0 if identical, else the 1-based index of the first
 *      mismatch. byte_count arrives in r2 here too (same one-ref-then-
 *      one-i64 shape as the FIFO helpers above) -- test_compare_buffers
 *      below doesn't need this note since ITS byte_count follows TWO
 *      single-register refs, landing at the already-even r2 with no
 *      padding. */
.global test_fill_pattern
test_fill_pattern:
    push {r4}
    mov r4, #0
test_fill_loop:
    cmp r4, r2
    beq test_fill_done
    and r3, r4, #0xFF
    strb r3, [r0, r4]
    add r4, r4, #1
    b test_fill_loop
test_fill_done:
    pop {r4}
    mov r0, #0
    mov r1, #0
    bx lr

/* This is the function whose missing `mov r1, #0` actually broke a
 * caller once, not just a latent risk like the others in this file:
 * with `b` (this fn's own second argument) still sitting in r1 at
 * either return point below, a caller's OWN correct 3-term `(x!=0) ||
 * (y!=0) || (z!=0)` -- where z is this function's return value --
 * saw z's high word as a live heap pointer instead of 0, made the
 * full 64-bit z nonzero even though the intended (truncated, 32-bit)
 * "0 or a 1-based mismatch index" value was genuinely 0, and forced
 * the whole OR chain true. Every symptom this produced (an aggregate
 * pass/fail flag reading true despite every individual check printing
 * 0, and the failure disappearing the instant the term selecting THIS
 * function's return value was dropped from the boolean expression
 * during bisection) pointed at the boolean-chain codegen itself before
 * the actual cause -- an ABI violation one call away -- was checked
 * directly against the disassembly. Two real bugs stacked in the same
 * investigation: the AAPCS argument-register-pairing note on
 * sdhost_drain_fifo_to_buffer above, found first, then this AAPCS
 * return-register one, found only because fixing the first wasn't
 * enough to make the round-trip test's aggregate result trustworthy. */
.global test_compare_buffers
test_compare_buffers:
    push {r4, r5}
    mov r3, #0
test_cmp_loop:
    cmp r3, r2
    beq test_cmp_equal
    ldrb r4, [r0, r3]
    ldrb r5, [r1, r3]
    cmp r4, r5
    bne test_cmp_mismatch
    add r3, r3, #1
    b test_cmp_loop
test_cmp_mismatch:
    add r0, r3, #1
    pop {r4, r5}
    mov r1, #0
    bx lr
test_cmp_equal:
    pop {r4, r5}
    mov r0, #0
    mov r1, #0
    bx lr
