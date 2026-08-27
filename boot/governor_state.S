/* Dhruva Phase 5 -- tiny persistent power-governor state (ARM32).
 *
 * Same shape of problem as every other .bss-plus-accessor file in this
 * project: governor_step() runs from task_d (idle), which is
 * #[no_heap] -- no dhruva_alloc_bytes available -- and needs a value
 * (the last frequency actually applied) to survive across many
 * separate calls, one per idle wake. No top-level vani global exists
 * to hold it instead.
 *
 * Tracking the last-APPLIED frequency (not just the last-desired one)
 * is what lets governor_step() skip the mailbox round-trip entirely
 * on every idle wake where nothing has actually changed -- the common
 * case by far, since ready_count only crosses a governor threshold
 * occasionally, not every tick. */

.section ".bss"
.align 4
governor_last_applied_mhz:
    .word 0        /* 0 is not a real frequency level (see kernel_
                     * main.vani's frequency table) -- the .bss zero
                     * default naturally forces the very first
                     * governor_step() call to treat "apply" as new,
                     * exactly like fs_init's own "0 means never
                     * written" convention. */

/* Phase 5 step 2 -- fixed-size run-queue-depth history for the
 * smoothed scoring function (see kernel_main.vani's governor_desired_
 * freq_mhz_v2 and power/train_governor.py's own header comment for
 * why smoothing over a short window, not the instantaneous sample
 * alone, is what step 2 actually adds). h0 = most recent sample after
 * a push, h3 = oldest of the 4 kept. Zero-initialized by .bss, same
 * as every other piece of state in this file -- a fresh boot correctly
 * starts as if the last 4 samples were all "0 load." */
governor_history_h0:
    .word 0
governor_history_h1:
    .word 0
governor_history_h2:
    .word 0
governor_history_h3:
    .word 0

.section ".text"

.global governor_get_last_applied_mhz
governor_get_last_applied_mhz:
    ldr r0, =governor_last_applied_mhz
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global governor_set_last_applied_mhz
governor_set_last_applied_mhz:
    ldr r1, =governor_last_applied_mhz
    str r0, [r1]
    mov r0, #0
    mov r1, #0
    bx lr

/* i64 governor_history_push(i64 new_sample) -- shifts the window and
 * inserts new_sample as h0. Only ever needs r0-r2: h3=h2, h2=h1,
 * h1=h0(old), h0=new_sample, read/written oldest-first so no temp
 * beyond the value already in a register is needed. */
.global governor_history_push
governor_history_push:
    ldr r1, =governor_history_h2
    ldr r2, [r1]
    ldr r1, =governor_history_h3
    str r2, [r1]                     /* h3 = old h2 */
    ldr r1, =governor_history_h1
    ldr r2, [r1]
    ldr r1, =governor_history_h2
    str r2, [r1]                     /* h2 = old h1 */
    ldr r1, =governor_history_h0
    ldr r2, [r1]
    ldr r1, =governor_history_h1
    str r2, [r1]                     /* h1 = old h0 */
    ldr r1, =governor_history_h0
    str r0, [r1]                     /* h0 = new_sample */
    mov r0, #0
    mov r1, #0
    bx lr

.global governor_history_get0
governor_history_get0:
    ldr r0, =governor_history_h0
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global governor_history_get1
governor_history_get1:
    ldr r0, =governor_history_h1
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global governor_history_get2
governor_history_get2:
    ldr r0, =governor_history_h2
    ldr r0, [r0]
    mov r1, #0
    bx lr

.global governor_history_get3
governor_history_get3:
    ldr r0, =governor_history_h3
    ldr r0, [r0]
    mov r1, #0
    bx lr

/* i64 governor_history_reset() -- zeroes the window. Used after the
 * boot-time replay self-test (which deliberately drives the SAME
 * synthetic workload power/train_governor.py trained against through
 * this history buffer) so live operation starts clean, not carrying
 * over the last few synthetic samples from that test. */
.global governor_history_reset
governor_history_reset:
    mov r0, #0
    ldr r1, =governor_history_h0
    str r0, [r1]
    ldr r1, =governor_history_h1
    str r0, [r1]
    ldr r1, =governor_history_h2
    str r0, [r1]
    ldr r1, =governor_history_h3
    str r0, [r1]
    mov r1, #0
    bx lr

/* BCM2835 VideoCore mailbox property interface: real hardware ARM-core
 * clock control. Verified against QEMU's own model source (hw/misc/
 * bcm2835_mbox.c, hw/misc/bcm2835_property.c) before writing this, the
 * same discipline as every other MMIO peripheral in this project --
 * SET_CLOCK_RATE is explicitly marked "NYI" in QEMU's property
 * handler (it logs a warning, sets the tag's own response-length
 * field, and reports overall success, but never reads the clock id or
 * rate at all) -- confirmed SAFE to call under QEMU (no hang, no
 * crash, no real effect), exactly matching DHRUVA_ARCHITECTURE.md §7
 * Phase 5's own caveat that QEMU can't validate real wattage/frequency
 * changes for this phase. The protocol itself is written correct for
 * REAL hardware regardless, since that's what actually matters here.
 *
 * Mailbox registers, base 0x2000B800 (offsets confirmed against
 * QEMU's own bcm2835_mbox.c source):
 *   MAILBOX_READ   = base + 0x80
 *   MAILBOX_STATUS = base + 0x98  (bit31 = FULL, bit30 = EMPTY)
 *   MAILBOX_WRITE  = base + 0xA0
 * A mailbox call encodes (buffer_address & ~0xF) | channel in the
 * value written -- the buffer's own address must therefore be
 * 16-byte aligned, hence this being a static .bss buffer with
 * explicit alignment rather than something from the heap
 * (dhruva_alloc_bytes only guarantees 8-byte alignment, and vani has
 * no way to take a `mut ref i64`'s own address as an integer to
 * re-align it by hand even if it did). Channel 8 is the property-tag
 * interface (ARM -> VideoCore), the universal convention across every
 * bare-metal Pi reference this project has seen -- not independently
 * re-derived here, but the QEMU source confirms property-tag requests
 * are handled at all, which is the part that actually mattered to
 * verify empirically rather than assume. */
.section ".bss"
.align 4
governor_mbox_buf:
    .space 36    /* 9 words -- see the layout comment below */

.section ".text"

/* i64 governor_apply_freq_mhz(i64 mhz) -- returns 0 if the VideoCore
 * reported overall success (real hardware: the call went through;
 * confirming the rate was actually APPLIED would need a follow-up
 * GET_CLOCK_RATE, not attempted here -- see the file header for why
 * that wouldn't mean anything under QEMU regardless), 1 if no response
 * arrived within the bounded poll or the response didn't indicate
 * success. Bounded (not `while true`) on purpose: a real bare-metal
 * function calling into hardware that might just not be there (this
 * runs on real Pi 1 hardware eventually, but is being validated here
 * under QEMU first) must never be able to hang the caller forever. */
.global governor_apply_freq_mhz
governor_apply_freq_mhz:
    stmdb sp!, {r4-r9, lr}

    ldr r4, =governor_mbox_buf
    ldr r5, =1000000
    mul r6, r0, r5                  /* r6 = mhz * 1,000,000 = rate in Hz */

    mov r7, #36
    str r7, [r4, #0]                 /* buf[0]: total size (bytes) */
    mov r7, #0
    str r7, [r4, #4]                 /* buf[1]: request code */
    ldr r7, =0x00038002
    str r7, [r4, #8]                 /* buf[2]: tag = set clock rate */
    mov r7, #12
    str r7, [r4, #12]                /* buf[3]: value buffer size */
    mov r7, #0
    str r7, [r4, #16]                /* buf[4]: tag req/resp code */
    mov r7, #3
    str r7, [r4, #20]                /* buf[5]: clock id (3 = ARM) */
    str r6, [r4, #24]                /* buf[6]: rate in Hz */
    mov r7, #0
    str r7, [r4, #28]                /* buf[7]: skip setting turbo */
    str r7, [r4, #32]                /* buf[8]: end tag */

    mov r8, r4
    bic r8, r8, #0xF                 /* defensive -- buf is already
                                       * 16-byte aligned via .align 4 */
    orr r8, r8, #8                   /* channel 8: property tags */

    ldr r9, =0x2000B898              /* MAILBOX_STATUS */
    ldr r5, =100000                  /* bounded-poll iteration cap */

    mov r0, #0
gaf_wait_write:
    ldr r1, [r9]
    tst r1, #0x80000000              /* FULL */
    beq gaf_write_ready
    add r0, r0, #1
    cmp r0, r5
    blt gaf_wait_write
    mov r0, #1                       /* timed out -- give up, no hang */
    mov r1, #0
    ldmia sp!, {r4-r9, lr}
    bx lr

gaf_write_ready:
    ldr r1, =0x2000B8A0              /* MAILBOX_WRITE */
    str r8, [r1]

    mov r0, #0
gaf_wait_read:
    ldr r1, [r9]
    tst r1, #0x40000000              /* EMPTY */
    bne gaf_read_not_ready
    ldr r2, =0x2000B880              /* MAILBOX_READ */
    ldr r2, [r2]
    cmp r2, r8                       /* is this response ours? */
    beq gaf_got_response
gaf_read_not_ready:
    add r0, r0, #1
    cmp r0, r5
    blt gaf_wait_read
    mov r0, #1                       /* timed out */
    mov r1, #0
    ldmia sp!, {r4-r9, lr}
    bx lr

gaf_got_response:
    ldr r2, [r4, #4]                 /* buf[1]: overall response code */
    ldr r3, =0x80000000
    cmp r2, r3
    moveq r0, #0                     /* success */
    movne r0, #1
    mov r1, #0
    ldmia sp!, {r4-r9, lr}
    bx lr
